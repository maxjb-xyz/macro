#!/usr/bin/env bash
# Repair the object-storage section of an existing Macro self-host env file.
#
# The pre-v0.2.3 template shipped CHANGEME_ placeholders for every S3 bucket,
# DynamoDB table, and SQS queue, and an EMPTY LOCAL_AWS_URL. The result: every
# object-store call (profile-pic upload, document upload, attachments) failed
# because the AWS SDK loaded an empty endpoint and pointed at buckets/tables/
# queues that don't exist in LocalStack.
#
# This script rewrites that section in place with the deterministic LocalStack
# names the stack actually provisions (docker/localstack/init/ready.d/001-
# macro-resources.sh) and the code-owned catalog (tooling/xtask/crates/
# xtask_local/src/local/resources.rs). It is idempotent and backs up first.
#
# Usage:  tooling/selfhost/fix-object-storage.sh [.env.selfhost]

set -euo pipefail

ENV_FILE="${1:-.env.selfhost}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }

cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"

python3 - "$ENV_FILE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines()

# Deterministic LocalStack values — the same names LocalStack provisions at
# boot and the xtask code-owned catalog emits.
SET = {
    "LOCAL_AWS_URL": "http://localstack:4566",
    "AWS_REGION": "us-east-1",
    "AWS_DEFAULT_REGION": "us-east-1",
    "AWS_ACCESS_KEY_ID": "test",
    "AWS_SECRET_ACCESS_KEY": "test",
    "ATTACHMENT_BUCKET": "macro-email-attachments",
    "DOCUMENT_STORAGE_BUCKET": "doc-storage",
    "DOCX_DOCUMENT_UPLOAD_BUCKET": "docx-upload",
    "STATIC_STORAGE_BUCKET": "static-file-storage",
    "UPLOAD_STAGING_BUCKET": "bulk-upload-staging",
    "CALL_RECORDING_BUCKET_NAME": "macro-call-recording-local",
    "BACKFILL_JOBS_TABLE": "search-processing-backfill-jobs",
    "BULK_UPLOAD_REQUESTS_TABLE": "bulk-upload",
    "CONNECTION_GATEWAY_TABLE": "connection-gateway-table",
    "STATIC_FILE_SERVICE_DYNAMODB_TABLE_NAME": "static-file-metadata",
    "OVERRIDE_WEBHOOK_EVENT_QUEUE": "http://localstack:4566/000000000000/webhook-event-queue.fifo",
    "OVERRIDE_EMAIL_CRM_CLEANUP_QUEUE": "http://localstack:4566/000000000000/email-service-crm-cleanup-queue",
    "OVERRIDE_REMINDER_DISPATCH_QUEUE": "http://localstack:4566/000000000000/reminder-dispatch-queue",
    "OVERRIDE_CALENDAR_REMINDER_DISPATCH_QUEUE": "http://localstack:4566/000000000000/calendar-reminder-dispatch-queue",
    "DOCUMENT_UPLOAD_FINALIZER_QUEUE_URL": "http://localstack:4566/000000000000/document-upload-finalizer-queue",
}

# Queue OVERRIDE keys that must NOT be set: the code-owned bare-name defaults
# in macro_queues already match the LocalStack-provisioned names, and a
# CHANGEME_ placeholder here would point the service at a nonexistent queue.
REMOVE = {
    "OVERRIDE_CHAT_DELETE_QUEUE",
    "OVERRIDE_CONTACTS_QUEUE",
    "OVERRIDE_CONVERT_QUEUE",
    "OVERRIDE_DOCUMENT_DELETE_QUEUE",
    "OVERRIDE_DOCUMENT_TEXT_EXTRACTOR_QUEUE",
    "OVERRIDE_EMAIL_SCHEDULED_QUEUE",
    "OVERRIDE_GMAIL_INBOX_SYNC_QUEUE",
    "OVERRIDE_GMAIL_INBOX_SYNC_RETRY_QUEUE",
    "OVERRIDE_GMAIL_OPS_QUEUE",
    "OVERRIDE_GMAIL_OPS_RETRY_QUEUE",
    "OVERRIDE_LINK_MANAGER_QUEUE",
    "OVERRIDE_NOTIFICATION_QUEUE",
    "OVERRIDE_NOTIFICATION_INGRESS_QUEUE",
    "OVERRIDE_PUSH_NOTIFICATION_EVENT_HANDLER_QUEUE",
    "OVERRIDE_SEARCH_EVENT_QUEUE",
    "OVERRIDE_AI_PROJECTION_QUEUE",
    "OVERRIDE_SFS_DELETE_QUEUE",
    "OVERRIDE_SFS_UPLOADER_QUEUE",
    "OVERRIDE_STATIC_FILE_SERVICE_S3_EVENT_QUEUE_URL",
    "OVERRIDE_EMAIL_BACKFILL_QUEUE",
    "OVERRIDE_UPLOAD_EXTRACTOR_QUEUE",
    "OVERRIDE_ORGANIZATION_RETENTION_QUEUE",
}

out = []
seen = set()
for line in lines:
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        out.append(line)
        continue
    key = s.split("=", 1)[0].strip()
    if key in REMOVE:
        # Preserve the removed line as a comment so the operator can see what
        # changed, but clear it so the code-owned bare-name default applies.
        out.append(f"# {key}=  (cleared by fix-object-storage.sh: bare-name default applies)")
        seen.add(key)
        continue
    if key in SET:
        out.append(f"{key}={SET[key]}")
        seen.add(key)
        continue
    out.append(line)

for key, val in SET.items():
    if key not in seen:
        out.append(f"{key}={val}")

path.write_text("\n".join(out) + "\n")
print(f"repaired {path}: {len(SET)} values set, {len(REMOVE)} placeholder overrides cleared")
PY

echo "done. backup written to $ENV_FILE.bak.*"

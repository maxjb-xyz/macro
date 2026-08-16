#!/usr/bin/env bash
set -euo pipefail

endpoint="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
region="${AWS_DEFAULT_REGION:-us-east-1}"
account_id="000000000000"

awslocal_cmd() {
  awslocal --endpoint-url="$endpoint" --region "$region" "$@"
}

create_queue() {
  local name="$1"
  if [[ "$name" == *.fifo ]]; then
    awslocal_cmd sqs create-queue --queue-name "$name" --attributes FifoQueue=true >/dev/null || true
  else
    awslocal_cmd sqs create-queue --queue-name "$name" >/dev/null || true
  fi
}

for queue in \
  notification-queue \
  notification-ingress-queue \
  push-delivery-queue \
  webhook-event-queue.fifo \
  email-service-backfill-queue \
  email-service-crm-cleanup-queue \
  delete-chat-handler-queue \
  contacts-queue \
  convert-service-queue \
  delete-document-handler-queue \
  document-upload-finalizer-queue \
  document-text-extractor-lambda-queue \
  email-service-scheduled-queue \
  email-service-gmail-inbox-sync-queue \
  email-service-gmail-inbox-retry-queue \
  email-service-gmail-ops-queue \
  email-service-gmail-ops-retry-queue \
  email-service-refresh-queue \
  search-event-queue \
  ai-projection-queue \
  email-sfs-delete-queue \
  email-service-sfs-mapper-queue \
  static-file-s3-event-notification-queue \
  reminder-dispatch-queue \
  calendar-reminder-dispatch-queue \
  bulk-upload-queue \
  organization-retention-handler-queue
do
  create_queue "$queue"
done

for bucket in \
  macro-email-attachments \
  doc-storage \
  docx-upload \
  static-file-storage \
  bulk-upload-staging \
  macro-call-recording-local
do
  awslocal_cmd s3 mb "s3://$bucket" >/dev/null 2>&1 || true
  awslocal_cmd s3api put-bucket-cors \
    --bucket "$bucket" \
    --cors-configuration '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","PUT","POST","DELETE","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["ETag"],"MaxAgeSeconds":3600}]}' \
    >/dev/null || true
done

awslocal_cmd dynamodb create-table \
  --table-name bulk-upload \
  --attribute-definitions AttributeName=PK,AttributeType=S AttributeName=SK,AttributeType=S \
  --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[{"IndexName":"DocumentPkIndex","KeySchema":[{"AttributeName":"SK","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}]' \
  >/dev/null || true

awslocal_cmd dynamodb create-table \
  --table-name connection-gateway-table \
  --attribute-definitions AttributeName=PK,AttributeType=S AttributeName=SK,AttributeType=S \
  --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[{"IndexName":"ConnectionPkIndex","KeySchema":[{"AttributeName":"SK","KeyType":"HASH"},{"AttributeName":"PK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' \
  >/dev/null || true

awslocal_cmd dynamodb create-table \
  --table-name static-file-metadata \
  --attribute-definitions AttributeName=file_id,AttributeType=S \
  --key-schema AttributeName=file_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  >/dev/null || true

queue_url="$endpoint/$account_id/document-upload-finalizer-queue"
queue_arn="arn:aws:sqs:$region:$account_id:document-upload-finalizer-queue"
source_arn="arn:aws:s3:::doc-storage"
policy="$(printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"sqs:SendMessage","Resource":"%s","Condition":{"ArnEquals":{"aws:SourceArn":"%s"}}}]}' "$queue_arn" "$source_arn")"

awslocal_cmd sqs set-queue-attributes \
  --queue-url "$queue_url" \
  --attributes "Policy=$policy" \
  >/dev/null || true

awslocal_cmd s3api put-bucket-notification-configuration \
  --bucket doc-storage \
  --notification-configuration "{\"QueueConfigurations\":[{\"Id\":\"document-upload-finalizer\",\"QueueArn\":\"$queue_arn\",\"Events\":[\"s3:ObjectCreated:*\"]}]}" \
  >/dev/null || true

echo "Macro LocalStack resources ready"

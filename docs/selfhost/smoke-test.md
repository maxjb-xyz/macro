# Self-host smoke test spec

Status: operator-facing smoke contract for proving that the self-host Compose stack still works after boot, restart, update, and restore. This is a small acceptance test, not a load test or a production-readiness claim.

## Purpose

A self-host smoke run must prove four things:

1. The Compose model boots with the selected operator env file.
2. A real browser session can authenticate through passwordless email.
3. Core user state can be created, found, and served back through the stack.
4. That state survives container restart/recreate without deleting named volumes.

The smoke is valid for the integration class under test:

- Local disposable: `.env.example`, Mailpit, LocalStack, and development images are acceptable.
- Production-ish single host: operator `.env` or `.env.selfhost`, real public HTTPS URLs, real secrets, real SMTP or an explicitly disabled-email policy, durable object storage, and the hardening gates in `production-checklist.md`.

## Non-goals

- Do not use `docker compose down -v`; volume deletion is a destructive restore-test action, not smoke cleanup.
- Do not treat Mailpit or LocalStack success as proof that production SMTP or object storage is configured.
- Do not require Google, Gmail, GitHub, Stripe, push, LiveKit, AI/model, calendar, or analytics features unless the operator has explicitly enabled those providers.
- Do not record real secrets, one-time codes, session tokens, or private document contents in artifacts.

## Preflight

From the repository root, pick the env file and Compose overlays before starting:

```bash
# Local disposable smoke.
cp .env.example .env
export MACRO_ENV_FILE=$PWD/.env
export MACRO_COMPOSE_ENV=$PWD/.env

# Production-ish smoke uses an operator-owned file instead.
# export MACRO_ENV_FILE=$PWD/.env.selfhost
# export MACRO_COMPOSE_ENV=$PWD/.env.selfhost
```

Render the target Compose model:

```bash
docker compose --project-directory . \
  --env-file "$MACRO_COMPOSE_ENV" \
  config >/tmp/macro-selfhost-smoke.compose.yml
```

Acceptance:

- The command exits `0`.
- The rendered config uses the expected env file and overlays.
- Public URL values for a production-ish smoke are canonical HTTPS origins, not `localhost` or Compose hostnames.
- Unsupported integrations are either disabled by policy or expected to fail closed.

## Boot smoke

Start the stack without deleting volumes:

```bash
docker compose --project-directory . \
  --env-file "$MACRO_COMPOSE_ENV" \
  up -d --wait --wait-timeout 180

docker compose --project-directory . \
  --env-file "$MACRO_COMPOSE_ENV" \
  ps
```

Acceptance:

- Required containers are running and expected health checks are healthy.
- One-shot bootstrap jobs such as topic/bootstrap tasks have completed or exited successfully; they are not crash-looping.
- Logs show no repeated migration failures, auth bootstrap failures, queue provisioning failures, or worker crash loops.
- Local disposable runs may use `tooling/scripts/self-host-smoke.sh` to capture the cheap Compose, LocalStack, Mailpit, status, and log artifacts first.

## Seed or create test data

Use one of these paths. Prefer the seeded path for repeatable manual testing; use the organic path to prove creation through the product UI.

### Seeded path

```bash
just seed-scenario apply --file tooling/seed_cli/seed/scenarios/team-perms.json
just seed-scenario status --file tooling/seed_cli/seed/scenarios/team-perms.json
```

The scenario includes users, the Acme team/workspace shape, documents, tasks, channels, messages, calls, and emails. The seed output prints persona login links such as `alice@seed.macro.local`.

Acceptance:

- FusionAuth account creation succeeds, or the seed output explicitly reports the fallback used.
- `status` reports the scenario rows present.
- At least one seeded document, task, channel, and message is visible in the UI after login.

### Organic UI path

Log in as a smoke-only user and create a unique marker, for example `smoke-YYYYMMDD-HHMM-<short-random>`.

Create or edit, depending on what the current UI exposes:

- Workspace/team object: create a workspace/team/project if available; otherwise use the seeded Acme workspace/project.
- Document: create a document or edit the seeded `Q3 Plan` with the unique marker.
- Task: create a task or edit the seeded `Ship the tagging system` task with the unique marker.
- Channel/message: send a channel message containing the unique marker.
- File: upload a small disposable text file named with the same marker, then open or download it.

Acceptance:

- Every created or edited object is visible after a browser refresh.
- The file can be retrieved through the configured object-storage/static-file path.
- Logs do not show failed document-storage, static-file, search-processing, or notification worker handling for the smoke actions.

## Auth smoke

Local disposable smoke:

1. Open the app using the published frontend/proxy port from `docker compose ps`.
2. Log in with a seeded persona link or request passwordless login for a smoke email address.
3. If a code is required, read it from Mailpit. Mailpit is local smoke only.

Production-ish smoke:

1. Open the canonical HTTPS `BASE_URL` in a clean browser profile.
2. Request passwordless login for a smoke account controlled by the operator.
3. Receive the message through the configured SMTP path.
4. Complete the login without mixed-content, CORS, redirect URI, cookie, issuer, or audience errors.

Acceptance:

- Login completes from a clean browser.
- Cookies/session survive page reload.
- Browser-visible URLs use the canonical public origin for production-ish smoke.
- Mailpit is used only for local disposable smoke; real-user production smoke must use real SMTP or explicitly mark passwordless email unavailable by policy.

## Product smoke

Run these checks in one browser session, using the unique marker when possible:

1. Document/storage: open a document, create or edit content, refresh, and verify the content persists.
2. Task: create or edit a task, refresh, and verify status/title/content persists.
3. Channel/message: send a message in a seeded or created channel; with a second persona, verify the message appears to another user with access.
4. Search: search for the unique marker or seeded text such as `Q3 Plan`, `Design doc`, or `permissions`; verify the expected document/channel/message/task result appears.
5. File path: upload a small disposable file and open/download it through the app.
6. WebSocket/collaboration: open the same document or channel in two persona sessions and verify edits, presence, or messages arrive without a full refresh.
7. Worker-backed queues: after upload/search/message actions, inspect recent logs for `document_upload_finalizer`, `search_processing_service`, `email_pubsub_workers`, and related services; there must be no crash loop or repeated processing failure.

Acceptance:

- At least one document or task and one channel/message state change persists.
- Search finds either the unique marker or expected seeded content.
- File upload/download works through the configured storage path.
- WebSocket or live update behavior works for a second persona, or the failure is recorded as a product/manual smoke failure.
- Queue-backed processing has no crash loops in the relevant worker logs.

## Restart and persistence smoke

Do not destroy volumes. Restart/recreate containers only:

```bash
docker compose --project-directory . \
  --env-file "$MACRO_COMPOSE_ENV" \
  restart

# If the update path needs container recreation, use up -d again, not down -v.
docker compose --project-directory . \
  --env-file "$MACRO_COMPOSE_ENV" \
  up -d --wait --wait-timeout 180
```

After restart:

1. Confirm `docker compose ps` returns to the expected running/healthy state.
2. Log in again from a clean or refreshed browser session.
3. Reopen the smoke document/task/channel/message/file by direct UI navigation or search.
4. Search again for the unique marker or seeded content.
5. Inspect logs for restart loops, failed migrations, lost Kafka/OpenSearch state, auth errors, or object-storage read failures.

Acceptance:

- The same user can log in after restart.
- The document/task/channel/message/file created or edited before restart is still present.
- Search still returns the expected result after restart.
- No stateful service loses its named volume state.
- No required long-running service remains unhealthy or repeatedly restarts.

## Update, backup, and restore integration

Use this smoke after every backup, restore, image update, env change, or rollback:

1. Before change: record commit, Compose files, env checksum, image tags, and backup ID.
2. Run the boot, auth, product, and search smoke.
3. Apply the change or restore procedure.
4. Run the restart/persistence smoke against pre-existing content.
5. Create one new post-change marker and verify it persists.
6. Record whether rollback would require only image/env/Compose restoration or a database/object-storage restore.

A restore drill is not accepted until this smoke passes on the restored host with pre-restore content visible.

## Disabled integration checks

For every integration classified as `external-required` or `stubbed` in `docs/selfhost/integrations.md`:

- If disabled, the UI should not advertise the feature as ready, or the action should fail closed with a clear operator/user-safe error.
- If enabled, the smoke must include a minimal provider-specific callback/webhook/API path using the canonical HTTPS host.
- Missing credentials must be recorded as `operator decision`, not as Compose boot success.

Minimum first provider order after core smoke passes:

1. Passwordless email through Mailpit, then real SMTP.
2. S3 upload/download through LocalStack, then durable object storage.
3. Google OAuth/Gmail if enabled.
4. GitHub OAuth/App/webhook if enabled.
5. Stripe test checkout/webhook if enabled.
6. Webhook delivery and queue processing if enabled.

## Evidence bundle

Store evidence under `artifacts/self-host-smoke/<timestamp>/` or the operator's equivalent private location.

Required files:

- `summary.env`: commit, Compose files, env-file path or checksum, image tags, start/end timestamps, smoke marker, and operator initials.
- `compose-config.{cmd,out,err,exit}`.
- `compose-up.{cmd,out,err,exit}` or host-test equivalent.
- `compose-ps-before-restart.{cmd,out,err,exit}` and `compose-ps-after-restart.{cmd,out,err,exit}`.
- `auth-smoke.md`: login method, provider class, result, and redacted notes.
- `product-smoke.md`: document/task/channel/search/file/websocket/worker result table.
- `restart-persistence-smoke.md`: pre-restart marker, post-restart verification, and remaining failures.
- `logs-tail.out`: redacted recent logs for failed or relevant services.
- `failure-log.md`: every failure classified with one bucket.

Do not attach `.env`, one-time codes, cookies, JWTs, provider credentials, or private user data.

## Failure buckets

Use exactly one bucket per issue:

- `environment`: Docker daemon, host resources, port conflicts, permissions, disk, DNS, or TLS certificate provisioning outside the app.
- `compose/config`: invalid Compose interpolation, missing env, wrong overlay, image pull/build, network, or volume wiring before services start.
- `service/startup`: container exits, healthcheck fails, migration fails, bootstrap fails, or service crash loop.
- `runtime/dependency`: Postgres, Redis, Kafka, OpenSearch, FusionAuth, SMTP/Mailpit, S3/LocalStack, SQS/DynamoDB, or another dependency is running but unusable.
- `product/manual`: auth, document, task, channel, search, upload/download, websocket, or worker-backed product behavior fails after the stack is otherwise healthy.
- `operator decision`: production provider, TLS, object storage, backup, observability, disabled feature, or policy choice is missing.

## Minimum pass definition

A passing self-host smoke has:

- Compose config and boot success for the selected overlays and env file.
- Passwordless login through the expected mail path.
- A created or edited document/task and channel/message visible after refresh.
- Search returning expected seeded content or the smoke marker.
- File upload/download working through the configured storage path.
- WebSocket/live update behavior verified or explicitly tracked as a product/manual failure.
- Restart/recreate with named volumes preserved and the same state visible afterward.
- No unexplained crash loops or repeated worker failures in logs.
- All disabled or unconfigured integrations classified rather than hidden.

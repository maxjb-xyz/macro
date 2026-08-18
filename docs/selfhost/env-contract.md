# Self-host environment contract

This document is the operator contract for `.env.selfhost.example`. It replaces
local-only stubs with explicit production-ish configuration classes without
committing real secrets.

## Classification model

| Class | Meaning | File policy |
| --- | --- | --- |
| `internal secret` | Secret material used only between Macro-owned services, FusionAuth, signing, or encryption. | Example values must be `CHANGEME_*`; operators rotate and store them in an external secret store or protected env file. |
| `public URL` | Browser-facing origin, OAuth callback, issuer, CDN, webhook, or proxy URL. | Example values may use `https://*.example.com`; operators replace them with real HTTPS domains before exposing users. |
| `integration key` | Credential, ID, webhook secret, app key, provider queue, or provider-specific ARN owned by a third-party account. | Keep the key visible. Leave blank only when the feature is intentionally not configured; otherwise replace with provider values. |
| `local default` | Compose service hostname, internal port, local queue/table name, or non-secret setting that is safe for the single-host overlay. | May ship with a working default when it is not a production secret. |
| `disabled feature` | Product surface that currently has local stubs or no self-host-specific disable switch. | Do not delete its env surface. Leave credentials blank where boot permits and document the feature as disabled/stubbed. If boot requires a non-empty value, use an obvious `CHANGEME_*` placeholder and do not claim the feature works. |

## Required production-ish env groups

### Compose and process defaults

| Keys | Class | Policy |
| --- | --- | --- |
| `MACRO_ENV_FILE`, `ENVIRONMENT`, `PORT`, `FRONTEND_PORT`, `KAFKA_TOPIC_PARTITIONS` | `local default` | `MACRO_ENV_FILE` should point at the operator copy, usually `.env.selfhost`. `ENVIRONMENT` accepts `local`, `selfhost`/`self_host` (both resolve secrets from the env file, not AWS Secrets Manager), `dev`, or `prod`. Ports and topic partitions may be tuned by the operator. |

### Public deployment identity

| Keys | Class | Policy |
| --- | --- | --- |
| `BASE_URL`, `FUSIONAUTH_OAUTH_REDIRECT_URI`, `ISSUER`, `SENDER_BASE_ADDRESS` | `public URL` | Must be real public HTTPS hostnames/sender domain before real users. Do not use Compose hostnames or `localhost` in a durable deployment. The `fusionauth_sync_config` one-shot service PATCHes `BASE_URL`/`FUSIONAUTH_OAUTH_REDIRECT_URI` (and the SMTP block below) into FusionAuth on every boot, since kickstart only runs on a fresh database. |
| `FUSIONAUTH_PUBLIC_URL` | `public URL` | Browser-reachable FusionAuth origin for SSO login/logout. A **separate host** — the `macroauth.` subdomain — routed to FusionAuth's published port `9011` (e.g. a Cloudflare Tunnel route `macroauth.example.com` → `http://localhost:9011`). Also drives FusionAuth's `FUSIONAUTH_APP_URL` (`fusionauth-app.url`). Without it, Google/GitHub SSO and logout redirect to the internal `fusionauth:9011`/`localhost` and fail. **Must be a single-level subdomain** (one label below the zone apex): Cloudflare's free Universal SSL wildcard `*.example.com` covers `app.example.com` but NOT `macroauth.app.example.com`, which fails HTTPS with a TLS handshake error ("uses an unsupported protocol"). The frontend derives its logout URL as `macroauth.<registrable-domain>`, so keep this in lockstep with `BASE_URL`. |
| `SYNC_ALLOWED_ORIGINS` | `public URL` (optional) | Document-sync websocket CORS allowlist (the sync-service worker rejects any `Origin` not on its list, which surfaces as "you're offline" on documents). Defaults to `BASE_URL` when unset. Comma-separate multiple origins if the app is also served from another domain (e.g. a preview/vanity domain). |
| `PROXY_HTTP_PORT`, `PROXY_HTTPS_PORT` | `local default` | Host ports the Caddy proxy publishes (defaults `80`/`443`). Behind a Cloudflare Tunnel, set `PROXY_HTTP_PORT` to the port the tunnel targets (e.g. `8054`); `PROXY_HTTPS_PORT` is then unused since Cloudflare terminates TLS. These live in `.env`, never edit `compose.yml` directly. |
| `AUDIENCE` | `internal secret` | Must match the real FusionAuth application/client ID. |

### Core data services

| Keys | Class | Policy |
| --- | --- | --- |
| `DATABASE_URL`, `DATABASE_URL_READONLY`, `MACRO_DB_URL`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `DATABASE_USER` | `internal secret` | Database credentials are operator-owned. Back up Macro and FusionAuth databases separately. |
| `REDIS_URI`, `REDIS_HOST`, `LAST_ONLINE_REDIS_URI`, `DOCUMENT_STORAGE_SERVICE_REDIS_URI`, `KAFKA_BROKERS`, `OPENSEARCH_URL` | `local default` | Compose service hostnames are valid for single-host Compose. Operators may externalize, but must preserve container reachability. |
| `OPENSEARCH_USERNAME`, `OPENSEARCH_PASSWORD` | `internal secret` | Local OpenSearch disables security; durable deployments need auth/TLS credentials or a documented equivalent. |

### Object storage, queues, and tables

Self-host ships a durable LocalStack (S3/SQS/DynamoDB). The values below are
the **deterministic names LocalStack provisions at boot**
(`docker/localstack/init/ready.d/001-macro-resources.sh`) and the code-owned
catalog (`tooling/xtask/crates/xtask_local/src/local/resources.rs`). They are
**not secrets** — leave them at the shipped defaults.

| Keys | Class | Policy |
| --- | --- | --- |
| `LOCAL_AWS_URL` | `local default` | **Must be set to `http://localstack:4566`** (LocalStack). An *empty* value is not "real AWS" — the AWS SDK then loads an empty endpoint and every object-store call (PFP upload, document upload, attachments) fails. To use real AWS, remove the variable entirely (not empty) and supply real credentials. |
| `S3_PUBLIC_BASE_URL` | `public URL` (self-host) | Public origin for browser-facing S3 presigned URLs. When set, presigned URLs are rewritten to `{S3_PUBLIC_BASE_URL}/s3/{bucket}/{key}` (the proxy routes `/s3/*` back to LocalStack) so a remote browser can reach them — `localhost:4566` only works on the host itself. Set to the same origin as `BASE_URL`. |
| `AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `local default` | LocalStack test credentials (`test`/`test`). Replace with real provider credentials only if you externalize object storage. |
| `ATTACHMENT_BUCKET`, `DOCUMENT_STORAGE_BUCKET`, `DOCX_DOCUMENT_UPLOAD_BUCKET`, `STATIC_STORAGE_BUCKET`, `UPLOAD_STAGING_BUCKET`, `CALL_RECORDING_BUCKET_NAME` | `local default` (deterministic) | Must match the LocalStack-provisioned bucket names (`doc-storage`, `macro-email-attachments`, …). |
| `BACKFILL_JOBS_TABLE`, `BULK_UPLOAD_REQUESTS_TABLE`, `CONNECTION_GATEWAY_TABLE`, `STATIC_FILE_SERVICE_DYNAMODB_TABLE_NAME` | `local default` (deterministic) | Must match the LocalStack-provisioned table names. `BACKFILL_JOBS_TABLE` is self-created by `search_processing_service` on startup. |
| `OVERRIDE_WEBHOOK_EVENT_QUEUE`, `OVERRIDE_EMAIL_CRM_CLEANUP_QUEUE`, `OVERRIDE_REMINDER_DISPATCH_QUEUE`, `OVERRIDE_CALENDAR_REMINDER_DISPATCH_QUEUE`, `DOCUMENT_UPLOAD_FINALIZER_QUEUE_URL` | `local default` (deterministic) | Full LocalStack queue URLs. Most other queues resolve from code-owned bare-name defaults in `macro_queues`; do **not** set their `OVERRIDE_*` vars. |
| `ENABLE_EMAIL_SCHEDULED_QUEUE`, `ENABLE_GMAIL_OPS_QUEUE` | `local default` | Enable only when the corresponding queues and credentials are configured. |

### Internal service secrets

| Keys | Class | Policy |
| --- | --- | --- |
| `INTERNAL_API_SECRET_KEY`, `INTERNAL_API_KEY`, `INTERNAL_AUTH_KEY`, `AUTHENTICATION_SERVICE_SECRET_KEY`, `SYNC_SERVICE_AUTH_KEY`, `DOCUMENT_PERMISSION_JWT`, `DOCUMENT_STORAGE_SERVICE_AUTH_KEY`, `SERVICE_INTERNAL_AUTH_KEY`, `INTERNAL_CALL_SECRET`, `URL_SIGNING_HMAC`, `JWT_SECRET_KEY` | `internal secret` | Generate unique high-entropy values. Where two services must agree, use one shared operator-managed secret and record ownership outside git. |

### Compose-internal service URLs

| Keys | Class | Policy |
| --- | --- | --- |
| `OVERRIDE_AUTH_SERVICE_URL`, `OVERRIDE_CONNECTION_GATEWAY_URL`, `OVERRIDE_DOCUMENT_STORAGE_SERVICE_URL`, `OVERRIDE_EMAIL_SERVICE_URL`, `OVERRIDE_LEXICAL_SERVICE_URL`, `OVERRIDE_STATIC_FILE_SERVICE_URL`, `OVERRIDE_SYNC_SERVICE_URL`, `OVERRIDE_AI_EDITING_WORKER_URL` | `local default` | These are intentionally Compose-internal service hostnames. Do not replace them with public URLs unless the service is deliberately externalized. |

### FusionAuth bootstrap

| Keys | Class | Policy |
| --- | --- | --- |
| `FUSIONAUTH_BASE_URL` | `local default` | Service-to-service FusionAuth URL inside Compose. |
| `FUSIONAUTH_CLIENT_ID`, `FUSIONAUTH_TENANT_ID`, `AUDIENCE` | `deterministic` | Fixed UUIDs baked into `kickstart.json` (client `22222222-…`, tenant `11111111-…`). Not secrets — keep them exactly as-is or auth, kickstart, and the sync one-shot disagree. |
| `ISSUER` | `deterministic` | The FusionAuth tenant issuer, baked into `kickstart.json` as `local.macro.com`. The backend validates the JWT `iss` claim against it — a mismatch 401s every authenticated request. |
| `FUSIONAUTH_API_KEY`, `FUSIONAUTH_API_KEY_SECRET_KEY` | `internal secret` | The FusionAuth API key; both must hold the **same** value (auth service reads `*_SECRET_KEY`, kickstart/sync read the bare key). Created by kickstart on **first boot only** — changing it later does nothing until the FusionAuth volume is reset or the key is rotated in the admin UI. |
| `FUSIONAUTH_CLIENT_SECRET_KEY` | `internal secret` | OAuth client secret for the Macro application. |
| `FUSIONAUTH_ADMIN_EMAIL`, `FUSIONAUTH_ADMIN_PASSWORD` | `internal secret` | FusionAuth admin login (kickstart creates `admin@macro.com`). Required for kickstart to complete; missing value aborts the bootstrap. |

### Email delivery

| Keys | Class | Policy |
| --- | --- | --- |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD_SECRET_KEY` | `integration key` | Real passwordless email requires a relay, sender domain, SPF/DKIM/DMARC, and bounce/complaint policy. Mailpit is local smoke only. |

### Signed URL / CDN compatibility

| Keys | Class | Policy |
| --- | --- | --- |
| `DOCUMENT_STORAGE_SERVICE_CLOUDFRONT_DISTRIBUTION_URL`, `EMAIL_SERVICE_CLOUDFRONT_DISTRIBUTION_URL` | `public URL` | Public file-serving origins. Operators may use CloudFront or a self-host-compatible substitute, but must keep URL signing semantics explicit. |
| `DOCUMENT_STORAGE_SERVICE_CLOUDFRONT_SIGNER_PUBLIC_KEY_ID`, `DOCUMENT_STORAGE_SERVICE_CLOUDFRONT_SIGNER_PRIVATE_KEY`, `DOCUMENT_STORAGE_SERVICE_CLOUDFRONT_SIGNER_PRIVATE_KEY_SECRET_NAME`, `EMAIL_SERVICE_CLOUDFRONT_SIGNER_PUBLIC_KEY_ID`, `EMAIL_SERVICE_CLOUDFRONT_SIGNER_PRIVATE_KEY` | `internal secret` | Local paths bypass real signing. Durable deployments need signing keys or a documented disabled/substitute policy. |

### Optional/external integrations

| Area | Keys | Class | Disabled/stubbed policy |
| --- | --- | --- | --- |
| Google login/Gmail | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET_KEY`, `GMAIL_GCP_QUEUE`, `GMAIL_POLL_INTERVAL_SECS` | `integration key` | `GMAIL_GCP_QUEUE` blank falls back to polling: links + backfill work and new mail is polled every `GMAIL_POLL_INTERVAL_SECS` (default 300). Set a topic for near-real-time push. Google login still requires OAuth consent, API scopes, and HTTPS callbacks. |
| GitHub login/sync | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_IDP_ID`, `GITHUB_SYNC_APP_URL`, `GITHUB_SYNC_APP_CLIENT_ID`, `GITHUB_SYNC_APP_CLIENT_SECRET`, `GITHUB_INSTALLATION_STATE_SECRET`, `GITHUB_WEBHOOK_SECRET_KEY`, `GITHUB_SYNC_APP_PEM_SECRET_KEY` | `integration key` | Requires OAuth/GitHub App setup and webhook delivery. Keep blank or `CHANGEME_*` until configured. |
| Stripe billing | `STRIPE_SECRET_KEY`, `STRIPE_PRICE_ID`, `STRIPE_WEBHOOK_SECRET_KEY` | `integration key` | Billing is not self-host-ready until the operator decides product/billing policy and webhook routing. |
| Push notifications | `APPLE_BUNDLE_ID`, `SNS_FCM_PLATFORM_ARN`, `SNS_APNS_PLATFORM_ARN` | `integration key` | Mobile push stays disabled/stubbed without Apple/FCM/SNS or equivalent delivery. |
| Model providers and MCP | `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CEREBRAS_API_KEY`, `COHERE_API_KEY`, `MCP_CREDENTIALS_KEY_SECRET_NAME`, `SLACK_MCP_CLIENT_ID`, `SLACK_MCP_CLIENT_SECRET` | `integration key` / `internal secret` | Bring-your-own-key: operators set their own provider keys. The model router requires `ANTHROPIC_API_KEY` + `OPENAI_API_KEY` + `CEREBRAS_API_KEY`. When blank or `local-*`/`CHANGEME_*` stubs, AI requests return a clean "model provider not configured" error instead of a confusing provider failure. MCP OAuth needs provider app credentials and credential encryption. |
| LiveKit calls | `LIVEKIT_SERVER_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | `integration key` | LiveKit is the only supported SFU. Default to LiveKit Cloud (works behind Cloudflare Tunnel/CGNAT; free tier 5,000 min + 50 GB/mo, then ~$0.004/min audio, ~$0.015/min video). Self-host `livekit-server` on a VPS with public UDP as the alternative, not on the app host behind Cloudflare Tunnel where WebRTC media can't traverse. |
| Calendar/webhooks | `CAL_WEBHOOK_SECRET_KEY`, `CAL_EVENT_TYPE_CONTENT_NAMES_KEY`, `CALENDAR_SYNC_ENABLED`, `CALENDAR_SCOPE_ENABLED` | `integration key` / `disabled feature` | Defaults off in `.env.selfhost.example`. Enable only after callback routing and secret rotation are configured. |
| Analytics/ads pixels | `META_PIXEL_ID`, `META_ACCESS_TOKEN` | `integration key` / `disabled feature` | Tracking should remain disabled unless the operator explicitly opts in and documents privacy policy. |
| Apollo enrichment | `APOLLO_API_KEY` | `integration key` | Leave blank when enrichment is disabled. |
| Macro API tokens | `MACRO_API_TOKEN_ISSUER`, `MACRO_API_TOKEN_PUBLIC_KEY`, `MACRO_API_TOKEN_PRIVATE_SECRET_KEY`, `MACRO_API_TOKEN_EXPIRY_SECONDS` | `internal secret` / `public URL` | Configure only when API-token validation/issuance is part of the deployment contract. |

## Stub and disabled integration policy

1. LocalStack, Mailpit, dummy OAuth credentials, local CDN signing stubs, analytics
   stubs, push-notification ARNs, and dummy model-provider keys are allowed only
   in disposable local smoke files such as `.env.example`.
2. `.env.selfhost.example` keeps every known env surface visible, but uses blanks
   or `CHANGEME_*` placeholders instead of fake working credentials.
3. If a service currently requires a value at boot for an unsupported provider,
   the operator may set an obvious `CHANGEME_DISABLED_BY_POLICY_*` placeholder to
   satisfy config loading, but the feature must remain disabled from the public
   runbook and smoke checklist.
4. Do not remove services or env keys merely to make Compose boot. Missing
   product-level disable switches should be tracked as product-policy work, not
   hidden in the self-host overlay.
5. A deployment is production-ish only after the operator has real public HTTPS,
   real internal secrets, real SMTP or a disabled-email policy, durable object
   storage, provisioned queues/tables, and a tested backup/restore plan.

## Graceful-degradation flags

Unconfigured integrations fail closed instead of 500-ing:

- `GOOGLE_LOGIN_ENABLED`, `GITHUB_LOGIN_ENABLED`, `STRIPE_BILLING_ENABLED` —
  default `true`; an integration is active only when its flag is true *and* its
  credentials are real (non-blank, not a `local-*`/`CHANGEME_*` placeholder).
- `GMAIL_SYNC_ENABLED` — default `true` in code, `false` in generated self-host
  `.env`; when `false`, `/email/init` returns `GMAIL_NOT_CONFIGURED` (400)
  instead of failing on Gmail provider calls.
- `SELF_HOST_UNLOCK_ALL` — default `false` in code, `true` in generated
  self-host `.env`; when `true`, every user is treated as premium (professional
  + AI permissions injected; the Stripe-backed premium extractor passes), so no
  billing wall blocks any feature.
- Model providers (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CEREBRAS_API_KEY`) —
  bring-your-own-key; when blank or `local-*`/`CHANGEME_*` stubs, the AI model
  router returns a clean "model provider not configured" error instead of a
  provider failure.
- `GET /auth/capabilities` reports `{google_login, github_login, microsoft_login,
  stripe_billing}`; the web UI hides the matching connect cards when disabled.

## Source inventory

This contract was derived from:

- `.env.example`
- `docker/docker-compose.yml`
- `docker/docker-compose-databases.yml`
- `infra/stacks/fusionauth-instance/docker-compose.yml`
- `tooling/xtask/crates/xtask_local/src/local/local_env.rs`
- `docs/SELF_HOSTING_INTEGRATIONS.md`
- `docs/SELF_HOSTING_DURABLE.md`

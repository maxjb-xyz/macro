# Self-Hosted Integration Contract

Macro's self-host stack must preserve the product's integration surface. The
Compose path can emulate infrastructure dependencies locally, but it cannot
magically grant Google, GitHub, Stripe, Apple, model-provider, or deliverability
approvals. Treat `.env.example` as a bootable local contract and the table below
as the operator contract for replacing stubs with real providers.

## Support Classes

- `local`: provided by Docker Compose and expected to work without external
  credentials.
- `local-emulated`: backed by LocalStack, Mailpit, or another local substitute;
  enough for smoke tests, not a production provider.
- `external-required`: requires an operator-owned third-party account, approval,
  OAuth app, webhook, secret, or license before the feature is real.
- `stubbed`: present only so service config loaders boot; feature calls should
  fail closed or stay inert until real credentials are supplied.

## Integration Matrix

| Area | Compose support | Env contract | Operator notes |
| --- | --- | --- | --- |
| Postgres/pgvector | `local` | `DATABASE_URL`, `DATABASE_URL_READONLY`, `MACRO_DB_URL` | Durable deployments must back up Macro and FusionAuth databases separately. |
| Redis | `local` | `REDIS_URI`, `REDIS_HOST`, `LAST_ONLINE_REDIS_URI`, `DOCUMENT_STORAGE_SERVICE_REDIS_URI` | Used for cache, presence, rate limiting, and service coordination. |
| Kafka (Redpanda) | `local` | `KAFKA_BROKERS` | Compose runs single-node Redpanda (Kafka-API compatible, no JVM) instead of apache/kafka; `KAFKA_BROKERS` stays `kafka:29092`. Production sizing and retention are operator decisions. |
| OpenSearch | `local` | `OPENSEARCH_URL`, `OPENSEARCH_USERNAME`, `OPENSEARCH_PASSWORD` | Local security is disabled; production needs auth/TLS/resource sizing. |
| S3-compatible storage | `local-emulated` | `LOCAL_AWS_URL`, `AWS_*`, `DOCUMENT_STORAGE_BUCKET`, `ATTACHMENT_BUCKET`, `DOCX_DOCUMENT_UPLOAD_BUCKET`, `STATIC_STORAGE_BUCKET`, `UPLOAD_STAGING_BUCKET` | Compose starts LocalStack and provisions the local buckets. Long-lived deployments should use managed S3 or durable S3-compatible storage with retention and restore drills. |
| SQS/DynamoDB-style async infra | `local-emulated` | `OVERRIDE_*_QUEUE`, `*_TABLE`, `DOCUMENT_UPLOAD_FINALIZER_QUEUE_URL`, `GMAIL_GCP_QUEUE` | Compose starts LocalStack and provisions local queues/tables. Real deployments need queue creation, dead-letter policy, and retry/visibility settings. |
| FusionAuth | `local` | `FUSIONAUTH_*`, `JWT_SECRET_KEY`, `ISSUER`, `AUDIENCE` | Local kickstart is disposable. Operators must own tenant/app bootstrap, signing keys, SMTP, backups, and OAuth provider configuration. |
| Passwordless email | `local-emulated` | `SMTP_HOST`, `SMTP_PORT`, `SENDER_BASE_ADDRESS` | Compose starts Mailpit for local capture. Real users require SMTP/SES, sender domain, SPF/DKIM/DMARC, and bounce handling. |
| Google login and Gmail | `external-required` | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET_KEY`, `GMAIL_GCP_QUEUE` | Essential for Gmail-backed email. Requires Google OAuth consent, Gmail API scopes, Pub/Sub/watch configuration, and public HTTPS callback/webhook URLs. |
| GitHub login and PR sync | `external-required` | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_IDP_ID`, `GITHUB_SYNC_APP_*`, `GITHUB_INSTALLATION_STATE_SECRET`, `GITHUB_WEBHOOK_SECRET_KEY`, `GITHUB_SYNC_APP_PEM_SECRET_KEY` | Requires OAuth/GitHub App configuration, webhook delivery, installation flow, and signed app private key management. |
| Stripe billing | `external-required` | `STRIPE_SECRET_KEY`, `STRIPE_PRICE_ID`, `STRIPE_WEBHOOK_SECRET_KEY` | Local stubs let signup avoid real checkout paths. Production needs products/prices, webhook endpoint, and billing policy. |
| Webhooks/channel bots | `local-emulated` | `OVERRIDE_WEBHOOK_EVENT_QUEUE`, `SERVICE_INTERNAL_AUTH_KEY`, `INTERNAL_*` | Queue processing can be local; incoming real webhooks need public HTTPS routing and token/secret rotation. |
| CloudFront-style signed URLs | `stubbed` locally | `DOCUMENT_STORAGE_SERVICE_CLOUDFRONT_*`, `EMAIL_SERVICE_CLOUDFRONT_*` | Local AWS paths bypass real signing. Production needs CDN/domain/key-pair decisions or a self-host-compatible signed URL substitute. |
| Push notifications | `external-required` | `APPLE_BUNDLE_ID`, `SNS_APNS_PLATFORM_ARN`, `SNS_FCM_PLATFORM_ARN` | Mobile push needs Apple/FCM credentials and SNS or equivalent delivery. Local stubs are inert. |
| LiveKit calls | `external-required` | `LIVEKIT_SERVER_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | LiveKit is the only supported SFU. Default to LiveKit Cloud (works behind Cloudflare Tunnel/CGNAT; free tier 5,000 min + 50 GB/mo, then ~$0.004/min audio, ~$0.015/min video). Self-host `livekit-server` on a VPS with public UDP as the alternative, not on the app host behind Cloudflare Tunnel. |
| Model providers and AI tools | `external-required` | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `COHERE_API_KEY`, `MCP_CREDENTIALS_KEY_SECRET_NAME` | Boot stubs do not make model calls work. Operators need provider keys, rate limits, data policy, and encrypted credential storage. |
| MCP provider OAuth | `external-required` | `SLACK_MCP_CLIENT_ID`, `SLACK_MCP_CLIENT_SECRET`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | Provider credentials and redirect URLs must match the public host. |
| Apollo CRM enrichment | `external-required` | `APOLLO_API_KEY` | Code skips enrichment when no usable key is configured. |
| Calendar webhooks | `external-required` | `CAL_WEBHOOK_SECRET_KEY`, `CAL_EVENT_TYPE_CONTENT_NAMES_KEY`, `CALENDAR_SYNC_ENABLED`, `CALENDAR_SCOPE_ENABLED` | Real calendar sync requires provider webhook routing and secret rotation. |
| Analytics/ads pixels | `stubbed` | `META_PIXEL_ID`, `META_ACCESS_TOKEN` | Inert locally; production should decide whether tracking is enabled at all. |

## Local vs Real Provider Rules

1. A Compose boot success only proves the local/emulated/stubbed contract.
2. A feature is not self-host-ready until its external provider path has a
   documented callback URL, secret owner, rotation process, and smoke test.
3. Stub values must stay obviously fake in `.env.example`; real secrets belong
   in an operator-managed `.env` or secret manager.
4. Do not remove an integration from Compose just to make the stack boot. If a
   provider cannot be configured yet, keep the env surface visible and classify
   the behavior as `external-required` or `stubbed`.

## First Provider Smoke Targets

After host Docker validation works, test integrations in this order:

1. Passwordless email through Mailpit, then through real SMTP.
2. Google OAuth login, then Gmail inbox grant and sync.
3. GitHub OAuth/App installation, webhook receipt, and PR entity sync.
4. S3 upload/download through LocalStack, then through the selected durable
   object store.
5. Stripe checkout/webhook in test mode.
6. Webhook delivery and queue processing.

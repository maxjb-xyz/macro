# Integrations

How to turn on the external integrations for a self-hosted Macro: Google,
Gmail, GitHub, Stripe, Outlook, LiveKit calls, and AI model providers.

Two things to know up front:

1. By default the stack **unlocks every paywalled feature**
   (`SELF_HOST_UNLOCK_ALL=true`), so Stripe is optional, not a prerequisite.
2. Until an integration is configured it **degrades cleanly**: its endpoints
   return a `NOT_CONFIGURED` error instead of a 500, and the web UI hides the
   matching connect cards (driven by `GET /auth/capabilities`).

## What works out of the box vs. what needs you

| Area | Status | What to set |
| --- | --- | --- |
| Postgres, Redis, Redpanda (Kafka), OpenSearch | local — no credentials needed | nothing |
| S3, SQS, DynamoDB | local-emulated (LocalStack) | nothing for a smoke test; real AWS for production |
| FusionAuth + passwordless email | local-emulated (Mailpit) | real SMTP for real email |
| Google login + Gmail | external — needs you | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET_KEY` |
| GitHub login + PR sync | external — needs you | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_SYNC_APP_*` |
| Stripe billing | external — needs you (optional) | `STRIPE_SECRET_KEY`, `STRIPE_PRICE_ID`, `STRIPE_WEBHOOK_SECRET_KEY` |
| LiveKit calls | external — needs you | `LIVEKIT_SERVER_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` |
| AI models | external — needs you | `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CEREBRAS_API_KEY` |
| Push, Apollo, calendar, analytics | external or stubbed | see [`configuration.md`](configuration.md) |

For the full per-variable list, see [`configuration.md`](configuration.md).

## How an integration turns on

An integration is active only when **both** hold:

1. Its `*_ENABLED` flag is `true` (default).
2. Its credentials are **real** — non-blank and not a `local-*`/`CHANGEME_*`
   placeholder.

So your job per integration is: create the external app/keys, set the env vars
in `.env`, and (for login providers) let FusionAuth provision the identity
provider.

## FusionAuth identity providers are auto-provisioned

The `fusionauth_provision_idps` one-shot service creates the Google, GitHub,
and Microsoft identity providers automatically for every integration whose
credentials are set in `.env`. It is idempotent. Re-run it after changing
credentials:

```bash
docker compose run --rm fusionauth_provision_idps
```

---

## 1. Google — login + Gmail sync (do this first)

Covers both "Sign in with Google" and Gmail-backed email. Both use the **same**
Google OAuth client; they differ only in the scopes.

### 1a. Create the OAuth client

1. Google Cloud Console → APIs & Services → Credentials → Create credentials →
   **OAuth client ID** → application type **Web application**.
2. Add authorized redirect URIs (replace the domains with yours):
   - `https://<app host>/oauth2/google/callback`
   - `https://<macroauth host>/oauth2/callback`

   The `<macroauth host>` must be a **single-level subdomain** (for example
   `macroauth.example.com`, not `macroauth.app.example.com`). Cloudflare's free
   wildcard cert covers only one label, so a two-level host fails HTTPS.
3. Note the **Client ID** and **Client secret**.

### 1b. Set env vars

```bash
GOOGLE_CLIENT_ID=<client-id>.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET_KEY=<secret>
GMAIL_SYNC_ENABLED=true
```

### 1c. Gmail push (optional)

For near-real-time inbox sync, set up GCP Pub/Sub:

1. Create a Pub/Sub topic in the same GCP project.
2. Grant `gmail-api-push@system.gserviceaccount.com` the Pub/Sub Publisher role.
3. Create a push subscription delivering to Macro's Gmail webhook
   (`POST /gmail/webhook`) and expose that route publicly.
4. Set `GMAIL_GCP_QUEUE=projects/<project-id>/topics/<topic-name>`.

Without Pub/Sub, Gmail falls back to polling every `GMAIL_POLL_INTERVAL_SECS`
(default 300). Pub/Sub is only needed for near-real-time delivery.

---

## 2. GitHub — login + PR sync

1. GitHub → Settings → Developer settings → **OAuth Apps** (login) and/or a
   **GitHub App** (repository/PR sync).
2. Set the callback to `https://<app host>/oauth2/github/callback`.
3. Set env vars:

```bash
GITHUB_CLIENT_ID=<…>
GITHUB_CLIENT_SECRET=<…>
# PR sync (GitHub App):
GITHUB_SYNC_APP_CLIENT_ID=<…>
GITHUB_SYNC_APP_CLIENT_SECRET=<…>
GITHUB_SYNC_APP_PEM_SECRET_KEY=<…>
GITHUB_WEBHOOK_SECRET_KEY=<…>
```

The `github` identity provider is auto-provisioned like Google.

---

## 3. Stripe billing

Self-host unlocks every paywalled feature by default
(`SELF_HOST_UNLOCK_ALL=true`), so **no Stripe account is required**. Wire
Stripe only if you want to run your own billing:

```bash
STRIPE_SECRET_KEY=sk_live_…
STRIPE_PRICE_ID=price_…
STRIPE_WEBHOOK_SECRET_KEY=whsec_…
```

---

## 4. Microsoft / Outlook

```bash
MICROSOFT_CLIENT_ID=<…>
MICROSOFT_CLIENT_SECRET=<…>
MICROSOFT_TENANT_ID=<…>
```

All three must be set together. The `microsoft` IdP is auto-provisioned, but it
requires a **real** tenant ID (FusionAuth validates the issuer at creation).

---

## 5. LiveKit calls

Calls use LiveKit — it is the only supported SFU. Cloudflare Calls, Jitsi, and
other SFUs are not drop-in replacements.

| Path | Who it's for | Cost |
| --- | --- | --- |
| **LiveKit Cloud** (recommended) | Any host, including behind Cloudflare Tunnel | Free tier 5,000 min + 50 GB/mo, then ~$0.004/min audio, ~$0.015/min video |
| Self-hosted LiveKit on a VPS | Operators with a box with a public IP + clean UDP | VPS cost only |
| Self-hosted LiveKit on the app host | Not supported | n/a |

Why Cloud is the default: Cloudflare Tunnel carries HTTP/WebSocket only, and
WebRTC media is UDP. A self-hosted LiveKit on the same box would signal fine
but carry no media.

```bash
LIVEKIT_SERVER_URL=wss://<project>.livekit.cloud
LIVEKIT_API_KEY=<key>
LIVEKIT_API_SECRET=<secret>
```

---

## 6. AI model providers (bring-your-own-key)

The AI surface calls Anthropic, OpenAI, and Cerebras directly with keys you
supply — there is no Macro-hosted proxy, so usage bills to your own accounts.

```bash
ANTHROPIC_API_KEY=sk-ant-…
OPENAI_API_KEY=sk-…
CEREBRAS_API_KEY=…
```

The model router requires all three. When any is blank or still a
`local-*`/`CHANGEME_*` stub, AI requests fail cleanly with a "model provider
not configured" error.

---

## Verify

After setting vars and creating the IdPs, restart the affected services and
confirm:

```bash
curl -s https://<host>/auth/capabilities
# → {"google_login":true,"github_login":false,...}
```

End-to-end confirmation per provider: Google login completes, Gmail backfill
enqueues and threads appear, GitHub PRs sync, Stripe test checkout completes.

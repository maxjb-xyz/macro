# Self-Host Integration Runbook

How to turn the external integrations (Google/Gmail, GitHub, Stripe, Outlook)
on for a self-hosted Macro deployment, using operator-owned OAuth/API
credentials supplied via environment variables. AI model providers are
bring-your-own-key (§5).

By default the self-host stack **unlocks every paywalled feature**
(`SELF_HOST_UNLOCK_ALL=true`), so Stripe is optional, not a prerequisite.

Until an integration is configured it **degrades cleanly**: its endpoints return
a `INTEGRATION_NOT_CONFIGURED`/`GMAIL_NOT_CONFIGURED` response instead of a 500,
and the web UI hides the matching connect cards (driven by `GET /auth/capabilities`).

## How an integration turns "on"

An integration is active only when **both** hold:

1. Its `*_ENABLED` flag is `true` (default).
2. Its credentials are **real** — non-blank and not a `local-*`/`CHANGEME_*`
   placeholder. (`generate-secrets.sh` ships placeholder values; the
   placeholder check in the auth service treats them as "not configured".)

So the operator's job per integration is: create the external app/keys, set the
matching env vars in `.env`, and (for the OAuth login providers) create the
corresponding identity provider in FusionAuth. `GMAIL_SYNC_ENABLED` has no
placeholder-detectable credential, so it is an explicit switch (default `false`
in generated self-host `.env`).

## FusionAuth identity providers are auto-provisioned

The `fusionauth_provision_idps` one-shot Compose service provisions the
Google/GitHub/Microsoft identity providers automatically, for every integration
whose credentials are set in `.env`. It runs after FusionAuth is healthy, is
idempotent (each IdP has a fixed Id; re-runs update in place), and is a no-op
when no integration is configured.

Re-run it after changing credentials:

```bash
docker compose run --rm fusionauth_provision_idps
```

The field-for-field IdP config below is what the provisioner applies (kept here
for reference and for manual creation via the admin UI if you prefer that).

---

## 1. Google OAuth — login + Gmail sync (priority)

Covers both "Sign in with Google" and Gmail-backed email (the core email
product). Both use the **same** Google OAuth client; they differ only in the
scopes the IdP requests.

### 1a. Create the Google OAuth client

1. Google Cloud Console → APIs & Services → Credentials → Create credentials →
   **OAuth client ID** → application type **Web application**.
2. Add authorized redirect URIs (replace the domains with yours):
   - `https://<BASE_URL host>/oauth2/google/callback` — the auth service's direct
     OAuth2 callback (`/link/gmail` and the Google login callback).
   - `https://<macroauth host>/oauth2/callback` — FusionAuth's OpenID Connect IdP
     callback (`{FUSIONAUTH_PUBLIC_URL}/oauth2/callback`). Confirm the exact path
     in FusionAuth → Identity Providers → your IdP → OAuth2 callback URL.

   The `<macroauth host>` must be a **single-level subdomain** (e.g. `macroauth.example.com`,
   not `macroauth.app.example.com`). Cloudflare's free Universal SSL wildcard
   `*.example.com` covers only one label, so a two-level host has no cert and
   fails HTTPS with a TLS handshake error ("uses an unsupported protocol").
3. Note the **Client ID** and **Client secret** (`GOCSPX-…`).

### 1b. Set env vars in `.env`

```bash
GOOGLE_CLIENT_ID=<client-id>.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET_KEY=<GOCSPX-…>
GMAIL_SYNC_ENABLED=true
```

`google_login_enabled` defaults on; no explicit flag is needed once real creds
are present (the placeholder check flips it on).

### 1c. FusionAuth identity providers (auto-provisioned)

The provisioner creates **two** Google identity providers (generic OpenID
Connect, not FusionAuth's built-in "Google" type — the auth service and the IdP
must share the same OAuth client, and the endpoints stay per-IdP):

**`google`** — login IdP, scopes `openid profile email`:

```json
{
  "identityProvider": {
    "type": "OpenIDConnect",
    "name": "google",
    "enabled": true,
    "buttonText": "Google",
    "linkingStrategy": "LinkByEmail",
    "oauth2": {
      "authorization_endpoint": "https://accounts.google.com/o/oauth2/v2/auth?prompt=consent&access_type=offline",
      "token_endpoint": "https://oauth2.googleapis.com/token",
      "userinfo_endpoint": "https://openidconnect.googleapis.com/v1/userinfo",
      "client_id": "<GOOGLE_CLIENT_ID>",
      "client_secret": "<GOOGLE_CLIENT_SECRET_KEY>",
      "clientAuthenticationMethod": "client_secret_basic",
      "scope": "openid profile email",
      "uniqueIdClaim": "sub",
      "emailClaim": "email",
      "emailVerifiedClaim": "email_verified",
      "usernameClaim": "preferred_username"
    },
    "applicationConfiguration": {
      "<APPLICATION_ID>": { "enabled": true, "createRegistration": true }
    }
  }
}
```

**`google_gmail`** — Gmail data-source IdP (used by `/link/gmail`), with the full
Gmail/contacts/calendar scopes. Also attach a reconcile lambda (see
`infra/stacks/fusionauth-instance/templates/reconcile_secondary_idp_link.js`) to
block sign-in with an account that is linked as a secondary inbox:

```json
{
  "identityProvider": {
    "type": "OpenIDConnect",
    "name": "google_gmail",
    "enabled": true,
    "buttonText": "GoogleGmail",
    "linkingStrategy": "LinkByEmail",
    "oauth2": {
      "authorization_endpoint": "https://accounts.google.com/o/oauth2/v2/auth?prompt=consent&access_type=offline",
      "token_endpoint": "https://oauth2.googleapis.com/token",
      "userinfo_endpoint": "https://openidconnect.googleapis.com/v1/userinfo",
      "client_id": "<GOOGLE_CLIENT_ID>",
      "client_secret": "<GOOGLE_CLIENT_SECRET_KEY>",
      "clientAuthenticationMethod": "client_secret_basic",
      "scope": "openid profile email https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/contacts.other.readonly https://www.googleapis.com/auth/gmail.settings.basic https://www.googleapis.com/auth/calendar",
      "uniqueIdClaim": "sub",
      "emailClaim": "email",
      "emailVerifiedClaim": "email_verified",
      "usernameClaim": "preferred_username"
    },
    "applicationConfiguration": {
      "<APPLICATION_ID>": { "enabled": true, "createRegistration": true }
    }
  }
}
```

`<APPLICATION_ID>` is the FusionAuth application id (the `AUDIENCE` value in
`.env`). Create via the admin UI (Identity Providers → Add → OpenID Connect) or
`POST /api/identity-provider` with the FusionAuth API key.

### 1d. (Recommended) Gmail push via Google Cloud Pub/Sub

For near-real-time inbox sync, Macro watches Gmail via GCP Pub/Sub:

1. Create a Pub/Sub **topic** and a **pull subscription** in the same GCP project.
2. Grant the Google service account push to that topic, and configure the Gmail
   API push notification (`watch`) to that topic.
3. Set `GMAIL_GCP_QUEUE=<subscription name>` in `.env`.

Without Pub/Sub, backfill still works but live push notifications won't arrive.

---

## 2. GitHub OAuth — login + PR sync

### 2a. Create the GitHub app

1. GitHub → Settings → Developer settings → **OAuth Apps** (for login) and/or a
   **GitHub App** (for repository/PR sync, required for `GITHUB_SYNC_APP_*`).
2. Set the authorization callback URL to `https://<BASE_URL host>/oauth2/github/callback`
   (and FusionAuth's `/oauth2/callback` if signing in through the IdP).

### 2b. Set env vars

```bash
GITHUB_CLIENT_ID=<…>
GITHUB_CLIENT_SECRET=<…>
GITHUB_IDP_ID=<fusionauth-idp-uuid>     # id of the `github` IdP you create below
# PR sync (GitHub App):
GITHUB_SYNC_APP_CLIENT_ID=<…>
GITHUB_SYNC_APP_CLIENT_SECRET=<…>
GITHUB_SYNC_APP_PEM_SECRET_KEY=<…>
GITHUB_WEBHOOK_SECRET_KEY=<…>
```

### 2c. Create the FusionAuth `github` identity provider

Same OpenID Connect shape as Google above, with GitHub endpoints:

- authorization_endpoint: `https://github.com/login/oauth/authorize`
- token_endpoint: `https://github.com/login/oauth/access_token`
- userinfo_endpoint: `https://api.github.com/user`
- scope: `read:user user:email` (add `repo` for PR sync)
- `name`: `github`

---

## 3. Stripe billing

Self-host unlocks every paywalled feature by default (`SELF_HOST_UNLOCK_ALL=true`
in the generated `.env`), so **no Stripe account is required** — every user is
treated as premium and the billing wall is lifted. Wire Stripe only if you want
to run your own billing:

```bash
STRIPE_SECRET_KEY=sk_live_…
STRIPE_PRICE_ID=price_…
STRIPE_WEBHOOK_SECRET_KEY=whsec_…
```

Point the Stripe webhook at `https://<BASE_URL host>/webhooks/…` (confirm the
exact path in the auth service's webhook routes) and set the webhook secret.

---

## 4. Microsoft / Outlook

```bash
MICROSOFT_CLIENT_ID=<…>
MICROSOFT_CLIENT_SECRET=<…>
MICROSOFT_TENANT_ID=<…>
```

`microsoft_credentials()` requires all three set together (blank all three to
disable). Create the `microsoft` IdP in FusionAuth (OpenID Connect, Azure Entra
endpoints: `https://login.microsoftonline.com/<tenant>/v2.0/…`).

---

## 5. AI model providers (bring-your-own-key)

Macro's AI surface (chat models, AI editing, document cognition, projections)
calls Anthropic, OpenAI, and Cerebras **directly** with keys you supply — there
is no Macro-hosted proxy, so AI usage bills to your own provider accounts.

```bash
ANTHROPIC_API_KEY=sk-ant-…
OPENAI_API_KEY=sk-…
CEREBRAS_API_KEY=…            # Cerebras inference (OpenAI-compatible)
```

The model router (`crates/agent`) requires **all three**; `COHERE_API_KEY` is a
legacy key the current router does not consume. When any of the three is blank
or still a `local-*`/`CHANGEME_*` stub, AI requests fail cleanly with a "model
provider not configured" error instead of a confusing provider failure.

Model access itself is gated by the user's permissions, and
`SELF_HOST_UNLOCK_ALL` already grants the professional/AI permissions to every
user — so once the keys are set, every user can use the full model set.

---

## 6. Verification checklist

After setting the vars and creating the IdP(s), restart the affected services
and confirm:

```bash
# Each enabled provider should now report true:
curl -s https://<host>/auth/capabilities
# → {"google_login":true,"github_login":false,"microsoft_login":false,"stripe_billing":false}

# SSO initiation should redirect (not 404 INTEGRATION_NOT_CONFIGURED):
curl -s -o /dev/null -w '%{http_code}' 'https://<host>/auth/login/sso?idp_name=google'
# → 307 (redirect to Google), not 404

# Gmail init should attempt the flow (not GMAIL_NOT_CONFIGURED):
# … trigger a login and confirm /email/init no longer returns the 400 GMAIL_NOT_CONFIGURED code.
```

End-to-end confirmation for each provider:

1. **Google login**: "Sign in with Google" completes and lands in the app.
2. **Gmail**: connect an inbox; the backfill job enqueues and threads appear.
3. **GitHub**: link the account; PRs sync after installing the GitHub App.
4. **Stripe**: a test-mode checkout completes and the webhook updates the
   subscription.

---

## Notes / gaps

- **IdP auto-provisioning** is wired into the self-host stack via the
  `fusionauth_provision_idps` one-shot service (config-gated, idempotent). The
  Microsoft IdP requires a **real** tenant ID — FusionAuth validates the
  `oauth2.issuer` discovery URL at creation, so a placeholder tenant fails.
- **Real SMTP** is separate (FusionAuth `SMTP_*` vars) and required for
  passwordless login to reach real users — see the GAP analysis §2.
- **Post-login redirects on self-host** (`ENVIRONMENT=selfhost`) land back on
  the operator's own `BASE_URL` origin: the `original_url` allow-list and the
  default post-login redirect are config-driven rather than hardcoded to
  `macro.com`, and the OAuth login callback redirects like production instead
  of returning a bare 200 (localhost-dev behaviour).
- The "on" paths above are documented from the code; they are **not** smoke-tested
  end-to-end without real provider credentials. The "off" (graceful-degradation)
  path is verified.

#!/usr/bin/env python3
"""Provision FusionAuth identity providers for configured external integrations.

Config-gated: an integration is provisioned only when its credentials are set to
real (non-blank, non-placeholder) values. Idempotent: each IdP/lambda is created
once with a fixed Id and updated on subsequent runs, so re-running after a
credential change is safe.

Runs as a one-shot Compose service after FusionAuth is healthy. Exit code 0
means provisioning completed (including the "nothing configured" no-op case).

Env vars consumed:
  FUSIONAUTH_API_KEY, FUSIONAUTH_BASE_URL (default http://fusionauth:9011)
  GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET_KEY
  GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET
  MICROSOFT_CLIENT_ID / MICROSOFT_CLIENT_SECRET / MICROSOFT_TENANT_ID
"""

import json
import os
import sys
import urllib.error
import urllib.request

FUSIONAUTH_BASE_URL = os.environ.get("FUSIONAUTH_BASE_URL", "http://fusionauth:9011").rstrip("/")
API_KEY = os.environ.get("FUSIONAUTH_API_KEY", "")

APPLICATION_ID = os.environ.get("APPLICATION_ID", "22222222-2222-4222-8222-222222222222")
GOOGLE_IDP_ID = os.environ.get("GOOGLE_IDP_ID", "44444444-4444-4444-8444-444444444444")
GOOGLE_GMAIL_IDP_ID = os.environ.get("GOOGLE_GMAIL_IDP_ID", "55555555-5555-4555-8555-555555555555")
RECONCILE_LAMBDA_ID = os.environ.get("RECONCILE_LAMBDA_ID", "66666666-6666-4666-8666-666666666666")
GITHUB_IDP_ID = os.environ.get("GITHUB_IDP_ID", "77777777-7777-4777-8777-777777777777")
MICROSOFT_IDP_ID = os.environ.get("MICROSOFT_IDP_ID", "88888888-8888-4888-8888-888888888888")
RECONCILE_LAMBDA_PATH = os.environ.get(
    "RECONCILE_LAMBDA_PATH", "/reconcile_secondary_idp_link.js"
)


def is_placeholder(value):
    v = (value or "").strip()
    return v == "" or v.startswith("local-") or v.startswith("CHANGEME_")


def configured(*values):
    return all(v and not is_placeholder(v) for v in values)


def api(method, path, body=None):
    url = FUSIONAUTH_BASE_URL + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", API_KEY)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except urllib.error.URLError as e:
        print(f"  ! request failed: {e}", file=sys.stderr)
        return None, None


def upsert(resource, resource_id, body):
    """Create (POST) or update (PUT) a FusionAuth resource by fixed Id."""
    status, _ = api("GET", f"/api/{resource}/{resource_id}")
    if status == 200:
        return api("PUT", f"/api/{resource}/{resource_id}", body)
    return api("POST", f"/api/{resource}/{resource_id}", body)


def app_config():
    return {APPLICATION_ID: {"enabled": True, "createRegistration": True}}


def oauth2_body(**kwargs):
    """The FusionAuth `oauth2` object (snake_case endpoint keys + camelCase claims)."""
    return kwargs


def provision_idp(name, idp_id, oauth2):
    body = {
        "identityProvider": {
            "type": "OpenIDConnect",
            "name": name,
            "enabled": True,
            "debug": False,
            "buttonText": name,
            "linkingStrategy": "LinkByEmail",
            "oauth2": oauth2,
            "applicationConfiguration": app_config(),
        }
    }
    status, resp = upsert("identity-provider", idp_id, body)
    ok = status in (200, 201)
    print(f"  {'✓' if ok else '✗'} {name} ({idp_id}): HTTP {status}")
    if not ok:
        print(f"    {(resp or '')[:400]}", file=sys.stderr)
    return ok


def provision_google():
    if not configured(
        os.environ.get("GOOGLE_CLIENT_ID"), os.environ.get("GOOGLE_CLIENT_SECRET_KEY")
    ):
        print("Google: not configured (skipping)")
        return True

    # Reconcile lambda for google_gmail first (the IdP references it).
    try:
        with open(RECONCILE_LAMBDA_PATH) as f:
            lambda_body = f.read()
    except OSError as e:
        print(f"  ! cannot read reconcile lambda {RECONCILE_LAMBDA_PATH}: {e}", file=sys.stderr)
        lambda_body = None

    if lambda_body is not None:
        status, _ = upsert(
            "lambda",
            RECONCILE_LAMBDA_ID,
            {
                "lambda": {
                    "id": RECONCILE_LAMBDA_ID,
                    "name": "Reconcile Secondary IdP Link (self-host)",
                    "type": "OpenIDReconcile",
                    "enabled": True,
                    "body": lambda_body,
                }
            },
        )
        print(f"  {'✓' if status in (200, 201) else '✗'} reconcile lambda: HTTP {status}")

    client_id = os.environ["GOOGLE_CLIENT_ID"].strip()
    client_secret = os.environ["GOOGLE_CLIENT_SECRET_KEY"].strip()

    login_oauth2 = oauth2_body(
        authorization_endpoint="https://accounts.google.com/o/oauth2/v2/auth?prompt=consent&access_type=offline",
        token_endpoint="https://oauth2.googleapis.com/token",
        userinfo_endpoint="https://openidconnect.googleapis.com/v1/userinfo",
        client_id=client_id,
        client_secret=client_secret,
        clientAuthenticationMethod="client_secret_basic",
        scope="openid profile email",
        uniqueIdClaim="sub",
        emailClaim="email",
        emailVerifiedClaim="email_verified",
        usernameClaim="preferred_username",
    )

    gmail_oauth2 = oauth2_body(
        authorization_endpoint="https://accounts.google.com/o/oauth2/v2/auth?prompt=consent&access_type=offline",
        token_endpoint="https://oauth2.googleapis.com/token",
        userinfo_endpoint="https://openidconnect.googleapis.com/v1/userinfo",
        client_id=client_id,
        client_secret=client_secret,
        clientAuthenticationMethod="client_secret_basic",
        scope="openid profile email https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/contacts.other.readonly https://www.googleapis.com/auth/gmail.settings.basic https://www.googleapis.com/auth/calendar",
        uniqueIdClaim="sub",
        emailClaim="email",
        emailVerifiedClaim="email_verified",
        usernameClaim="preferred_username",
    )

    # Attach the reconcile lambda to google_gmail.
    gmail_body = {
        "identityProvider": {
            "type": "OpenIDConnect",
            "name": "google_gmail",
            "enabled": True,
            "debug": False,
            "buttonText": "GoogleGmail",
            "linkingStrategy": "LinkByEmail",
            "lambdaConfiguration": {"reconcileId": RECONCILE_LAMBDA_ID},
            "oauth2": gmail_oauth2,
            "applicationConfiguration": app_config(),
        }
    }
    a = provision_idp("google", GOOGLE_IDP_ID, login_oauth2)
    b_status, _ = upsert("identity-provider", GOOGLE_GMAIL_IDP_ID, gmail_body)
    b = b_status in (200, 201)
    print(f"  {'✓' if b else '✗'} google_gmail ({GOOGLE_GMAIL_IDP_ID}): HTTP {b_status}")
    return a and b


def provision_github():
    if not configured(
        os.environ.get("GITHUB_CLIENT_ID"), os.environ.get("GITHUB_CLIENT_SECRET")
    ):
        print("GitHub: not configured (skipping)")
        return True

    oauth2 = oauth2_body(
        authorization_endpoint="https://github.com/login/oauth/authorize",
        token_endpoint="https://github.com/login/oauth/access_token",
        userinfo_endpoint="https://api.github.com/user",
        client_id=os.environ["GITHUB_CLIENT_ID"].strip(),
        client_secret=os.environ["GITHUB_CLIENT_SECRET"].strip(),
        clientAuthenticationMethod="client_secret_basic",
        scope="openid profile email offline user:email offline_access",
        uniqueIdClaim="id",
        emailClaim="email",
        emailVerifiedClaim="email_verified",
        usernameClaim="preferred_username",
    )
    return provision_idp("github", GITHUB_IDP_ID, oauth2)


def provision_microsoft():
    if not configured(
        os.environ.get("MICROSOFT_CLIENT_ID"),
        os.environ.get("MICROSOFT_CLIENT_SECRET"),
        os.environ.get("MICROSOFT_TENANT_ID"),
    ):
        print("Microsoft: not configured (skipping)")
        return True

    oauth2 = oauth2_body(
        issuer=f"https://login.microsoftonline.com/{os.environ['MICROSOFT_TENANT_ID'].strip()}/v2.0",
        client_id=os.environ["MICROSOFT_CLIENT_ID"].strip(),
        client_secret=os.environ["MICROSOFT_CLIENT_SECRET"].strip(),
        clientAuthenticationMethod="client_secret_basic",
        scope="openid email offline_access profile Mail.ReadWrite Mail.Send",
        uniqueIdClaim="sub",
    )
    return provision_idp("microsoft", MICROSOFT_IDP_ID, oauth2)


def main():
    if not API_KEY:
        print("FUSIONAUTH_API_KEY is not set; cannot provision identity providers.", file=sys.stderr)
        return 1

    print(f"Provisioning FusionAuth identity providers against {FUSIONAUTH_BASE_URL}")
    results = [
        provision_google(),
        provision_github(),
        provision_microsoft(),
    ]
    if all(results):
        print("Done.")
        return 0
    print("Provisioning finished with errors.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

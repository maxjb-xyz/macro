#!/usr/bin/env python3
"""Sync FusionAuth application + tenant config from the self-host .env.

FusionAuth's kickstart only runs against a fresh database, so once the
FusionAuth volume exists the operator's domain and SMTP provider can never be
re-applied through kickstart. This one-shot service PATCHes the two pieces of
config that depend on the operator's environment, on every boot, idempotently:

  1. The Macro application's authorized OAuth redirect URLs — the frontend
     initiates passwordless login with `redirect_uri = <origin>/app`, but the
     kickstart hardcodes only localhost origins. Without the operator's origin
     in `authorizedRedirectURLs`, `/api/passwordless/start` is rejected and
     login silently fails.
  2. The default tenant's outbound email configuration (SMTP) — so a real
     provider can be wired after first boot, and the passwordless-login code
     email actually reaches the user's inbox instead of the local Mailpit sink.

Env vars consumed (all from .env):
  FUSIONAUTH_API_KEY           self-host API key (created by kickstart)
  FUSIONAUTH_BASE_URL          default http://fusionauth:9011
  FUSIONAUTH_CLIENT_ID         the Macro application id (default 22222222-…)
  BASE_URL                     public app origin, e.g. https://macro.example.com
  FUSIONAUTH_OAUTH_REDIRECT_URI public OAuth redirect, e.g. https://macro.example.com/oauth/redirect
  SMTP_HOST / SMTP_PORT / SMTP_SECURITY / SMTP_USERNAME / SMTP_PASSWORD
  SMTP_FROM_EMAIL / SMTP_FROM_NAME
"""

import json
import os
import sys
import urllib.error
import urllib.request

FUSIONAUTH_BASE_URL = os.environ.get("FUSIONAUTH_BASE_URL", "http://fusionauth:9011").rstrip("/")
API_KEY = os.environ.get("FUSIONAUTH_API_KEY", "")

APPLICATION_ID = os.environ.get("FUSIONAUTH_CLIENT_ID", "22222222-2222-4222-8222-222222222222")
TENANT_ID = os.environ.get("FUSIONAUTH_TENANT_ID", "11111111-1111-4111-8111-111111111111")


def api(method, path, body=None):
    url = FUSIONAUTH_BASE_URL + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", API_KEY)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        print(f"  ! HTTP {e.code}: {raw[:400]}", file=sys.stderr)
        return e.code, {}
    except urllib.error.URLError as e:
        print(f"  ! request failed: {e}", file=sys.stderr)
        return None, {}


def sync_redirect_urls():
    status, resp = api("GET", f"/api/application/{APPLICATION_ID}")
    if status != 200:
        print(f"  ✗ application GET: HTTP {status} — cannot sync redirect URLs")
        return False

    oauth = resp.get("application", {}).get("oauthConfiguration", {}) or {}
    urls = list(oauth.get("authorizedRedirectURLs") or [])

    added = []
    base_url = (os.environ.get("BASE_URL", "") or "").strip().rstrip("/")
    if base_url:
        for suffix in ("/app", "/oauth/redirect"):
            candidate = base_url + suffix
            if candidate not in urls:
                urls.append(candidate)
                added.append(candidate)

    oauth_redirect = (os.environ.get("FUSIONAUTH_OAUTH_REDIRECT_URI", "") or "").strip()
    if oauth_redirect and oauth_redirect not in urls:
        urls.append(oauth_redirect)
        added.append(oauth_redirect)

    if not added:
        print("  redirect URLs: already in sync (nothing to add)")
        return True

    status, _ = api(
        "PATCH",
        f"/api/application/{APPLICATION_ID}",
        {"application": {"oauthConfiguration": {"authorizedRedirectURLs": urls}}},
    )
    ok = status in (200, 201)
    print(f"  {'✓' if ok else '✗'} redirect URLs: HTTP {status}")
    for u in added:
        print(f"      + {u}")
    return ok


def sync_smtp():
    status, resp = api("GET", f"/api/tenant/{TENANT_ID}")
    if status != 200:
        print(f"  ✗ tenant GET: HTTP {status} — cannot sync email config")
        return False

    email = dict(resp.get("tenant", {}).get("emailConfiguration") or {})

    port_raw = (os.environ.get("SMTP_PORT", "") or "").strip()
    try:
        port = int(port_raw) if port_raw else 1025
    except ValueError:
        port = 1025

    email.update(
        {
            "host": (os.environ.get("SMTP_HOST", "") or "mailpit").strip(),
            "port": port,
            "security": (os.environ.get("SMTP_SECURITY", "") or "NONE").strip(),
            "username": (os.environ.get("SMTP_USERNAME", "") or ""),
            "password": (os.environ.get("SMTP_PASSWORD", "") or ""),
            "defaultFromEmail": (os.environ.get("SMTP_FROM_EMAIL", "") or "noreply@macro.local"),
            "defaultFromName": (os.environ.get("SMTP_FROM_NAME", "") or "Macro Local"),
        }
    )

    status, _ = api("PATCH", f"/api/tenant/{TENANT_ID}", {"tenant": {"emailConfiguration": email}})
    ok = status in (200, 201)
    print(f"  {'✓' if ok else '✗'} email/SMTP: HTTP {status} (host={email['host']}:{email['port']} security={email['security']})")
    return ok


def main():
    if not API_KEY:
        print("FUSIONAUTH_API_KEY is not set; cannot sync FusionAuth config.", file=sys.stderr)
        return 1

    print(f"Syncing FusionAuth config against {FUSIONAUTH_BASE_URL}")
    results = [sync_redirect_urls(), sync_smtp()]
    if all(results):
        print("Done.")
        return 0
    print("Sync finished with errors.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

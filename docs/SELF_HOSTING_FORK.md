# Self-Hosted Fork Maintenance

This fork tracks upstream Macro while proving out a self-hosted path around
Docker Compose first. Treat this as a compatibility fork, not a product fork:
keep upstream application code intact whenever possible, isolate self-hosting
changes in docs, Compose overlays, env defaults, and small adapters, and make the
cost of each divergence visible.

## Current Baseline

Upstream already ships a local Compose stack and a headless stack runner:

- `docs/RUNNING_LOCALLY.md` is the source of truth for booting Macro locally.
- `docker/docker-compose.yml` includes the app services and local dependencies.
- `docker/docker-compose-databases.yml` runs Postgres, Redis, Kafka, and
  OpenSearch.
- `infra/stacks/fusionauth-instance/docker-compose.yml` runs local FusionAuth.
- `just run_local --no-doppler` starts the interactive developer stack.
- `just stack up` starts the same topology headlessly with a built frontend.

The upstream public docs still describe self-hosting at a high level. They do
not yet define an operator-owned, long-lived Docker Compose deployment process.
For this fork, the first milestone is therefore a disposable local-equivalent
stack that can boot the full app and expose the missing production decisions.

## Milestone 0: Disposable Compose Stack

Use the upstream local stack without Doppler as the first self-host smoke test:

```bash
nix develop
just doctor-local --instance selfhost --port-base 31000
just stack up --instance selfhost --port-base 31000 --no-doppler
just stack status --instance selfhost --port-base 31000
just seed-scenario --instance selfhost --port-base 31000 apply --file seed/scenarios/team-perms.json
```

The app is served from the proxy URL printed by `just stack up` and
`just stack status`. Passwordless login emails are captured by Mailpit; use the
Mailpit URL printed by the stack status instead of expecting real email
delivery.

When finished:

```bash
just stack down --instance selfhost --port-base 31000
```

This milestone is intentionally disposable. It proves the service graph, local
AWS equivalents, auth, seed data, and browser entrypoint. It does not promise
durable data, external integrations, backups, TLS, real object storage, or
production-grade secrets.

## Validation Path

Before changing the self-host path, run the cheap checks:

```bash
just check
docker compose --project-directory . -f docker/docker-compose.yml config >/dev/null
```

For changes that affect boot or environment wiring, run a full disposable stack:

```bash
just doctor-local --instance selfhost --port-base 31000
just stack up --instance selfhost --port-base 31000 --no-doppler
just stack status --instance selfhost --port-base 31000 --json
just stack down --instance selfhost --port-base 31000
```

For user-facing smoke coverage, seed data and run the local E2E suite when the
machine has enough CPU, memory, Docker disk, and network access for browser
dependencies:

```bash
just local-e2e --instance selfhost-e2e --port-base 32000
```

## Self-Hosted Fork Plan

### Phase 1: Prove the Disposable Stack

The first goal is to prove that the upstream local stack can boot from this fork
without privileged Macro team access.

- Run the stack through `nix develop` and `just stack up --no-doppler`.
- Confirm the Compose topology resolves and creates deterministic networks,
  volumes, ports, and generated env files.
- Seed `seed/scenarios/team-perms.json` and confirm passwordless login through
  Mailpit.
- Smoke test auth, documents, channels/messages, search, file upload/download,
  WebSockets/collaboration, and background workers.
- Record every failure as either an upstream local-stack bug, a self-hosting
  gap, or an operator decision.

This phase is complete when a fresh checkout can bring up a disposable stack and
an operator can follow the runbook without guessing.

### Phase 2: Define the Operator Contract

After the disposable stack works, turn the local-equivalent path into an
operator-owned Compose contract.

- Add a self-host Compose overlay only where the upstream local stack is too
  developer-oriented.
- Add example env files for real secrets, domains, object storage, email,
  FusionAuth, and integration credentials.
- Decide how durable volumes, backups, restores, TLS, routing, CORS, cookies,
  and WebSockets are owned.
- Decide which services remain local containers and which may point at managed
  equivalents such as S3-compatible storage or external SMTP.
- Document the minimum host resources and expected failure modes.

This phase is complete when the repo describes a long-lived deployment shape,
not just a local development stack.

### Phase 3: Add Reliable Verification

The fork should not rely on manual inspection once upstream syncs begin.

- Keep `just check` as the cheap changed-file quality gate.
- Validate Compose config on every self-hosting change.
- Add a headless stack smoke that boots, seeds, logs in, and probes core product
  paths.
- Capture status output and logs as artifacts when the smoke fails.
- Add a release checklist for migrations, backups, rollback, and operator notes.

This phase is complete when a sync PR can say exactly what was tested and what
still needs manual review.

### Phase 4: Automate Upstream Sync

Once the manual sync process is boring, automate it.

- Schedule a bot job to fetch `macro-inc/macro` and create a short-lived sync
  branch.
- Attempt the merge into this fork, run the cheap gates, and open a draft PR if
  clean.
- Use Codex to resolve ordinary conflicts while preserving upstream application
  code and this fork's self-hosting layer.
- Escalate auth, sessions, database migrations, secrets, billing, permissions,
  queue/topic contracts, retention, and destructive data changes.
- Include upstream commit range, fork-only files touched, validation results,
  operator-facing changes, and known risks in every sync PR.

This phase is complete when upstream updates arrive as reviewable PRs instead
of untracked drift.

### Phase 5: Keep the Fork Small

Maintenance is mostly about resisting unnecessary divergence.

- Audit fork-only patches regularly.
- Upstream fixes that are generally useful.
- Delete temporary shims when upstream grows a cleaner path.
- Keep self-hosting code isolated in docs, Compose overlays, env defaults,
  small adapters, and local orchestration.
- Treat every new patch as an operator responsibility that needs validation and
  upgrade notes.

The fork is healthy when it is easy to explain how it differs from upstream and
routine upstream updates do not require archaeology.

## Fork Patch Rules

Prefer these locations for fork-only work:

- `docs/SELF_HOSTING_FORK.md` for operator and maintainer process.
- `docs/RUNNING_LOCALLY.md` for improvements that are also true upstream.
- `docker/` for Compose overlays, service image definitions, and local runtime
  wiring.
- `tooling/xtask/crates/xtask_local/` for reusable local/headless orchestration
  that should stay close to upstream's stack runner.
- `.github/workflows/` only after a process is proven manually.

Avoid these changes unless there is no smaller path:

- Editing service business logic only to satisfy a self-host environment.
- Forking generated service clients or schemas.
- Committing secrets, live OAuth credentials, private keys, or real customer
  endpoints.
- Adding cloud-provider-specific production infrastructure before the Compose
  path is well understood.

Every fork-only patch should answer:

1. Is this a temporary local-equivalent shim or a durable self-host contract?
2. Can it be upstreamed?
3. Which validation proves it still works after an upstream sync?
4. Which operator responsibility did it introduce?

## Known Gaps Before Production Self-Hosting

The Compose stack is enough for disposable local validation, but production
self-hosting still needs explicit decisions:

- Secrets: replace dummy local values with operator-managed secrets and rotation.
- Identity: configure real OAuth/SAML/OIDC providers and FusionAuth tenant data.
- Email: configure deliverability, inbound sync providers, webhook endpoints, and
  provider approvals.
- Object storage: choose local S3-compatible storage or managed S3, then define
  retention, lifecycle, and signed URL behavior.
- Data durability: backups, restores, migrations, disaster recovery, and volume
  ownership.
- TLS and routing: public hostnames, certificates, CORS, cookies, websocket
  routing, and reverse proxy hardening.
- Observability: logs, metrics, tracing, alerting, audit trails, and on-call runbooks.
- Upgrades: migration windows, rollback strategy, compatibility checks, and
  operator release notes.
- Security: image provenance, dependency scanning, secret scanning, network
  boundaries, admin access, and vulnerability response.
- Scale: queue sizing, worker concurrency, database connection limits, search
  capacity, and background job isolation.

## Upstream Sync Process

Run syncs on a short-lived branch and keep the bot-generated PR reviewable:

```bash
git remote add upstream https://github.com/macro-inc/macro.git 2>/dev/null || true
git fetch origin main
git fetch upstream main
git switch -c sync-upstream-$(date +%Y%m%d) origin/main
git merge --no-ff upstream/main
just check
docker compose --project-directory . -f docker/docker-compose.yml config >/dev/null
```

If the merge is clean and checks pass, open a draft PR into `maxjb-xyz/macro`
`main`. The PR body should include:

- upstream commit range
- fork-only files touched by the merge
- validation commands and results
- operator-facing changes, migrations, auth/security changes, and secret changes
- whether a disposable `just stack up --no-doppler` smoke was run

If conflicts happen, use Codex to resolve them in the sync branch and keep the
resolution scoped to preserving upstream plus this fork's self-host patches.
Escalate instead of auto-resolving when upstream changes touch:

- authentication, OAuth, sessions, cookies, or FusionAuth tenant behavior
- database migrations, data deletion, retention, or permission models
- secrets, encryption keys, signing keys, webhook verification, or billing
- queue/topic contracts and long-running background migrations
- changes that make the Compose smoke pass only by disabling a service

Future automation should perform the same steps on a schedule: fetch upstream,
attempt the merge, run `just check`, run Compose config validation, optionally
run the disposable stack smoke, and open a draft PR only when the result is
clean. Conflict resolution and security-sensitive changes should remain a human
or Codex-reviewed step, not an unattended push to `main`.

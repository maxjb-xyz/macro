# Self-Hosted Fork Maintenance

This fork tracks upstream Macro while proving out a self-hosted path around
Docker Compose first. Treat this as a compatibility fork, not a product fork:
keep upstream application code intact whenever possible, isolate self-hosting
changes in docs, Compose overlays, env defaults, and small adapters, and make the
cost of each divergence visible.

## Current Baseline

Upstream already ships a local Compose stack and optional developer runners:

- `docs/RUNNING_LOCALLY.md` is the source of truth for booting Macro locally.
- `docker/docker-compose.yml` includes the app services and local dependencies.
- `docker/docker-compose-databases.yml` runs Postgres, Redis, Kafka, and
  OpenSearch.
- `infra/stacks/fusionauth-instance/docker-compose.yml` runs local FusionAuth.
- `docker compose --project-directory . -f docker/docker-compose.yml up -d`
  starts the operator stack directly.
- `just run_local --no-doppler` and `just stack up` remain upstream developer
  conveniences around the same local topology.

The upstream public docs still describe self-hosting at a high level. They do
not yet define an operator-owned, long-lived Docker Compose deployment process.
For this fork, the first milestone is therefore a disposable local-equivalent
stack that can boot the full app and expose the missing production decisions.

## Milestone 0: Disposable Compose Stack

Use the upstream Compose stack as the first self-host smoke test:

```bash
docker compose --project-directory . -f docker/docker-compose.yml config >/dev/null
docker compose --project-directory . -f docker/docker-compose.yml up -d
docker compose --project-directory . -f docker/docker-compose.yml ps
```

Operators only need Docker with the Compose plugin for this Phase 1 path. Nix,
Rust, Cargo, and Just may be used by contributors while developing the fork, but
they are not required to start the self-host stack.

The app is served from the Compose-published proxy/frontend ports. Passwordless
login emails are captured by Mailpit; use the Mailpit container's published URL
instead of expecting real email delivery.

For a repeatable Phase 1 evidence capture, use the smoke wrapper:

```bash
tooling/scripts/self-host-smoke.sh
```

The wrapper runs the cheap Compose checks, starts the stack with
`docker compose up -d`, captures status/log/resource artifacts under
`artifacts/self-host-smoke/`, and leaves the stack running for browser checks.
Use `tooling/scripts/self-host-smoke.sh --down` when you only need machine
artifacts and want the stack reclaimed automatically. `just self-host-smoke` is
an optional contributor shortcut for the same script.

When finished:

```bash
docker compose --project-directory . -f docker/docker-compose.yml down
```

This milestone is intentionally disposable. It proves the service graph, local
AWS equivalents, auth, seed data, and browser entrypoint. It does not promise
durable data, external integrations, backups, TLS, real object storage, or
production-grade secrets.

## Validation Path

Before changing the self-host path, run the cheap checks:

```bash
docker compose --project-directory . -f docker/docker-compose.yml config >/dev/null
tooling/scripts/self-host-smoke.sh --skip-stack
```

For changes that affect boot or environment wiring, run a full disposable stack:

```bash
tooling/scripts/self-host-smoke.sh --down
```

Contributors can also run the upstream developer gates when Nix/Rust/Cargo/Just
are installed:

```bash
just check
just doctor-local --instance selfhost --port-base 31000
just stack up --instance selfhost --port-base 31000 --no-doppler
just stack status --instance selfhost --port-base 31000 --json
just seed-scenario --instance selfhost --port-base 31000 apply --file tooling/seed_cli/seed/scenarios/team-perms.json
just seed-scenario --instance selfhost --port-base 31000 matrix --file tooling/seed_cli/seed/scenarios/team-perms.json
just stack down --instance selfhost --port-base 31000
just local-e2e --instance selfhost-e2e --port-base 32000
```

## Self-Hosted Fork Plan

### Phase 1: Prove the Disposable Stack

The first goal is to prove that the upstream local stack can boot from this fork
without privileged Macro team access.

- Run the operator stack with
  `docker compose --project-directory . -f docker/docker-compose.yml up -d`.
- Confirm the Compose topology resolves and creates deterministic networks,
  volumes, ports, and generated env files.
- Seed `tooling/seed_cli/seed/scenarios/team-perms.json` and confirm
  passwordless login through Mailpit.
- Smoke test auth, documents, channels/messages, search, file upload/download,
  WebSockets/collaboration, and background workers.
- Record every failure as either an upstream local-stack bug, a self-hosting
  gap, or an operator decision.

This phase is complete when a fresh checkout can bring up a disposable stack and
an operator can follow the runbook without guessing.

#### Phase 1 Operator Runbook

Start from a fresh checkout on `main` and capture a clean working tree:

```bash
git status --short --branch
tooling/scripts/self-host-smoke.sh
```

The smoke wrapper writes one file per command under
`artifacts/self-host-smoke/<instance>-<timestamp>/`. Keep these files with the
validation notes for the PR or sync:

- `compose-config.out` proves the base Compose topology resolves.
- `compose-up.out` records the direct `docker compose up -d` operator startup.
- `compose-ps.out` records container state.
- `resource-names.txt`, `docker-network-inspect.out`, and
  `docker-volume-inspect.out` record the deterministic Compose project,
  networks, and volumes.
- `docker-ps.out` and `docker-logs.out` capture runtime evidence for follow-up
  debugging.
- When `just` and `cargo` are installed, optional `validate-local-compose.out`,
  `validate-local-env.out`, `seed-apply.out`, `seed-status.out`, and
  `seed-matrix.out` artifacts may be present as contributor evidence.

After `tooling/scripts/self-host-smoke.sh` succeeds, use the published Compose
ports to complete the browser checks in `manual-smoke-checklist.md`:

- Auth: open one of the seeded persona login links and confirm passwordless
  login completes; if the browser prompts for a code, read it from Mailpit.
- Documents: open a seeded document, edit content, reload, and confirm the
  change persists.
- Channels/messages: send a message in a seeded channel and confirm another
  persona with access can see it.
- Search: search for seeded document, channel, or message text and confirm the
  expected result appears.
- File upload/download: upload a small disposable file, then open or download it
  back through the app.
- WebSockets/collaboration: open the same document as two personas and confirm
  edits or presence arrive without a refresh.
- Background workers: trigger a queue-backed flow, then review `docker-logs.out`
  for successful worker processing and no crash loops.

Write every issue to `failure-log.md` and classify it exactly as one of:

- Upstream local-stack bug: the disposable local stack is expected to support
  the behavior, but the current upstream machinery fails.
- Self-hosting gap: the behavior needs fork-owned docs, Compose, env, or
  operator glue before it can be considered self-hostable.
- Operator decision: the behavior requires a production choice such as real
  secrets, domains, TLS, backups, external email, object storage, observability,
  retention, or scale settings.

When finished, reclaim the disposable stack:

```bash
docker compose --project-directory . -f docker/docker-compose.yml down
```

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

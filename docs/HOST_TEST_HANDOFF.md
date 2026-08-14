# Phase 1 Host-Test Handoff

This is the one-time host validation contract for Maximus. Use it only after a
PR is ready for Docker-daemon validation. Ordinary review and contributor
checks do not require a running Docker daemon, and no host test is requested by
this document until the repo is ready.

The operator path remains plain Docker Compose. From the repository root, the
exact handoff command is:

```bash
tooling/scripts/host-test-handoff.sh
```

The script uses `.env.example`, starts the existing `docker/docker-compose.yml`
with project name `macro`, captures evidence, and removes the stack on exit.
To use an operator-managed env file or leave the stack running for browser
checks:

```bash
tooling/scripts/host-test-handoff.sh --env-file .env --keep-stack
```

## Checklist

The host operator should attach the generated artifact directory to the PR and
complete these checks in order:

1. Confirm Docker Desktop/Engine is running and `daemon-info.exit` is `0`.
2. Confirm `compose-config.exit` is `0` and `compose-config.out` contains the
   resolved Compose model.
3. Confirm `compose-up.exit` is `0`.
4. Review `compose-ps.out`; containers needed by the stack should be running.
5. Confirm `localstack-health.exit`, `localstack-sqs.exit`,
   `localstack-s3.exit`, `localstack-dynamodb.exit`, and
   `mailpit-health.exit` are `0`; these prove the local integration substrates
   exist before browser testing.
6. Review `compose-logs.out` for startup errors or crash loops.
7. If `--keep-stack` was used, run the browser checks from
   `docs/SELF_HOSTING_FORK.md` and record results in `failure-log.md`.
8. Review `docs/SELF_HOSTING_INTEGRATIONS.md` and classify any integration
   failure as local infrastructure, local emulation, missing external
   credentials, or an intentionally stubbed provider.
9. Confirm the stack was reclaimed (`compose-down.exit` is `0`) unless the
   artifact records an intentional `--keep-stack` handoff.

## Artifact format

Each command has three files: `<name>.cmd` (exact command), `<name>.out`, and
`<name>.err`; `<name>.exit` contains the numeric exit status. The expected
minimum bundle is:

```text
manifest.env
docker-version.{cmd,out,err,exit}
daemon-info.{cmd,out,err,exit}
compose-version.{cmd,out,err,exit}
compose-config.{cmd,out,err,exit}
compose-up.{cmd,out,err,exit}
compose-ps.{cmd,out,err,exit}
localstack-health.{cmd,out,err,exit}
localstack-sqs.{cmd,out,err,exit}
localstack-s3.{cmd,out,err,exit}
localstack-dynamodb.{cmd,out,err,exit}
mailpit-health.{cmd,out,err,exit}
compose-logs.{cmd,out,err,exit}
compose-down.{cmd,out,err,exit}
failure-log.md
```

`manifest.env` records the tested commit, Compose file, env-file choice, and
UTC timestamps. Do not attach `.env` or any file containing real secrets.

## Failure buckets

Use exactly one bucket per issue in `failure-log.md`:

- `environment`: Docker missing, daemon unavailable, permissions, port
  collision, disk, or host resource limits.
- `compose/config`: invalid interpolation, missing env value, image pull, or
  network/volume/project wiring failure before services start.
- `service/startup`: a container exits, health check fails, migration fails, or
  logs show a crash loop during startup.
- `runtime/dependency`: local Postgres, Redis, Kafka, OpenSearch, LocalStack,
  FusionAuth, or another dependency is running but not usable.
- `product/manual`: the stack is healthy but an auth, document, messaging,
  search, upload, collaboration, or worker browser check fails.

Include the failing `<name>.exit`, relevant `.err`, and the last useful section
of `compose-logs.out` with each entry. An unavailable Docker daemon is an
`environment` result; it is not evidence of an application failure.

The default Compose stack keeps app services and local dependencies on Docker
networks only. Do not add host port mappings to resolve a service-to-service
failure; Macro services should use Compose hostnames such as
`lexical-service:8096`, `localstack:4566`, `fusionauth:9011`, `postgres:5432`,
and `kafka:29092`. Add host-published ports only in an explicit debug or public
overlay.

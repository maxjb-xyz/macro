#!/usr/bin/env python3
"""Flatten the Macro self-host Compose sources into a single `compose.yml`.

Why: Docker Compose's `include:` directive cannot override a service that an
included file already defines. v2.24+ errors with
"services.<name> conflicts with imported resource"; older versions silently
first-win (the override is ignored). Both are wrong for the layered
base + frontend + hardening + release-image stack. So instead of `include:` we
deep-merge the source files here into ONE self-contained file with no
`include:`, no anchors, and no `-f` flags. Operators deploy it with a bare
`docker compose up -d`; maintainers run this script when a source file changes
(e.g. after rebasing upstream).

Source merge order (later wins):
  1. docker/docker-compose-databases.yml
  2. infra/stacks/fusionauth-instance/docker-compose.yml
  3. docker/docker-compose.yml
  4. docker/selfhost/compose.frontend.yml
  5. docker/selfhost/compose.production.yml
  6. docker/selfhost/compose.light-infra.yml
  7. docker/selfhost/compose.release-images.yml

`!reset null` / `!reset []` in a later source means "drop this key" (revert to
Compose default): `build` is removed (pull, don't build), `command` is removed
(run the image's baked-in entrypoint), `volumes` is removed (drop dev
bind-mounts).
"""

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]

SOURCES = [
    "docker/docker-compose-databases.yml",
    "infra/stacks/fusionauth-instance/docker-compose.yml",
    "docker/docker-compose.yml",
    "docker/selfhost/compose.frontend.yml",
    "docker/selfhost/compose.production.yml",
    "docker/selfhost/compose.light-infra.yml",
    "docker/selfhost/compose.release-images.yml",
]

HEADER = """# ============================================================================
# Macro self-host — production stack (GENERATED FILE — do not edit by hand).
#
# `docker compose up -d --wait` boots the full production deployment: upstream
# base services + databases + FusionAuth + the self-host frontend proxy/durable
# storage + production hardening, with every Macro service pinned to an
# immutable GHCR release image. No COMPOSE_FILE and no `-f` flags required.
#
# This file is FLATTENED from the layered sources below (see
# tooling/selfhost/flatten-compose.py). Edit those, then regenerate:
#   python3 tooling/selfhost/flatten-compose.py
#
#   docker/docker-compose-databases.yml
#   infra/stacks/fusionauth-instance/docker-compose.yml
#   docker/docker-compose.yml                     (upstream base, untouched)
#   docker/selfhost/compose.frontend.yml          (proxy + durable storage)
#   docker/selfhost/compose.production.yml        (restart/logging/limits)
#   docker/selfhost/compose.light-infra.yml       (Redpanda swap + node heap caps)
#   docker/selfhost/compose.release-images.yml    (GHCR image pins)
#
# Release-image source: MACRO_RELEASE_IMAGE_REGISTRY + MACRO_RELEASE_IMAGE_TAG
# in the operator's .env (defaults in .env.example).
# ============================================================================
"""

# The databases and FusionAuth files are included by the base file WITHOUT a
# `project_directory`, so their relative host paths are written against the
# file's own directory. The flattened file lives at the repo root, so those
# paths must be rebased to repo-root-relative here.
REBASES = {
    "docker/docker-compose-databases.yml": {
        "../crates/macro_db_client/migrations": "./crates/macro_db_client/migrations",
        "./selfhost/migrate-macrodb.sh": "./docker/selfhost/migrate-macrodb.sh",
        "./selfhost/bootstrap-macrodb.sh": "./docker/selfhost/bootstrap-macrodb.sh",
        "../infra/local/opensearch": "./infra/local/opensearch",
    },
    "infra/stacks/fusionauth-instance/docker-compose.yml": {
        "./kickstart": "./infra/stacks/fusionauth-instance/kickstart",
    },
}


class _Reset:
    pass


RESET = _Reset()


class _Loader(yaml.SafeLoader):
    pass


def _construct_reset(loader, node):
    return RESET


_Loader.add_constructor("!reset", _construct_reset)


class _NoAliasDumper(yaml.SafeDumper):
    """Dump every value inline instead of emitting `&idN`/`*idN` aliases."""

    def ignore_aliases(self, data):
        return True


def load(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.load(f, Loader=_Loader)
    return data or {}


def _rebase_string(s, mapping):
    for old, new in mapping.items():
        if s == old:
            return new
        if s.startswith(old + ":"):  # volume short syntax 'host:container[:mode]'
            return new + s[len(old):]
        if s.startswith(old + "/"):
            return new + s[len(old):]
    return s


def _rebase(data, mapping):
    if isinstance(data, dict):
        return {k: _rebase(v, mapping) for k, v in data.items()}
    if isinstance(data, list):
        return [_rebase(v, mapping) for v in data]
    if isinstance(data, str):
        return _rebase_string(data, mapping)
    return data


def deep_merge(base, override):
    if isinstance(override, _Reset):
        return None
    if isinstance(base, dict) and isinstance(override, dict):
        out = dict(base)
        for k, v in override.items():
            if k in out:
                merged = deep_merge(out[k], v)
                if merged is None:
                    del out[k]
                else:
                    out[k] = merged
            elif not isinstance(v, _Reset) and v is not None:
                out[k] = v
        return out
    if isinstance(base, list) and isinstance(override, list):
        return override
    return override


def main() -> None:
    merged: dict = {}
    for rel in SOURCES:
        data = load(REPO_ROOT / rel)
        data.pop("include", None)
        mapping = REBASES.get(rel)
        if mapping:
            data = _rebase(data, mapping)
        merged = deep_merge(merged, data)

    # Anchor definitions (x-*) are fully inlined into each service now.
    for k in list(merged.keys()):
        if k.startswith("x-"):
            del merged[k]

    # Stable, readable top-level key order.
    order = ["name", "services", "networks", "volumes"]
    ordered = {k: merged[k] for k in order if k in merged}
    for k, v in merged.items():
        if k not in ordered:
            ordered[k] = v

    body = yaml.dump(
        ordered,
        Dumper=_NoAliasDumper,
        sort_keys=False,
        default_flow_style=False,
        width=1000,
        allow_unicode=True,
    )

    out_path = REPO_ROOT / "compose.yml"
    out_path.write_text(HEADER + body, encoding="utf-8")

    n_svc = len(ordered.get("services", {}))
    print(f"wrote {out_path.relative_to(REPO_ROOT)} ({n_svc} services)")


if __name__ == "__main__":
    main()

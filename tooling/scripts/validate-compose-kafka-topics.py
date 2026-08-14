#!/usr/bin/env python3
"""Validate Docker-free Kafka topic wiring for the Compose self-host path."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TOPICS_MANIFEST = ROOT / ".github/kafka-cluster-topics.json"
ROOT_COMPOSE = ROOT / "compose.yml"
DATABASES_COMPOSE = ROOT / "docker/docker-compose-databases.yml"
APP_COMPOSE = ROOT / "docker/docker-compose.yml"


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def extract_init_topics(compose_text: str) -> list[str]:
    match = re.search(r"topics='\n(?P<body>.*?)\n\s*'", compose_text, re.S)
    if not match:
        fail("kafka_topics command is missing the topics block")
    return [line.strip() for line in match.group("body").splitlines() if line.strip()]


def main() -> None:
    expected_topics = json.loads(TOPICS_MANIFEST.read_text())
    databases_compose = DATABASES_COMPOSE.read_text()
    app_compose = APP_COMPOSE.read_text()
    root_compose = ROOT_COMPOSE.read_text()

    if "docker/docker-compose.yml" not in root_compose:
        fail("root compose.yml must include docker/docker-compose.yml")

    if "\n  kafka_topics:" not in databases_compose:
        fail("docker/docker-compose-databases.yml must define kafka_topics")

    actual_topics = extract_init_topics(databases_compose)
    if actual_topics != expected_topics:
        fail(
            "kafka_topics topic list does not match .github/kafka-cluster-topics.json\n"
            f"expected: {expected_topics}\n"
            f"actual:   {actual_topics}"
        )

    required_fragments = [
        "--if-not-exists",
        "--describe",
        "Kafka topic was not visible after creation",
    ]
    for fragment in required_fragments:
        if fragment not in databases_compose:
            fail(f"kafka_topics command is missing {fragment!r}")

    stale_dependency = re.search(
        r"\n      kafka:\n        condition: service_healthy",
        app_compose,
    )
    if stale_dependency:
        fail("app services must wait for kafka_topics, not raw kafka health")

    topic_dependencies = app_compose.count("condition: service_completed_successfully")
    if topic_dependencies < 7 or app_compose.count("kafka_topics:") < 7:
        fail("expected Kafka-backed app services to depend on kafka_topics completion")

    print(
        "Compose Kafka topic validation passed "
        f"({len(actual_topics)} topics, {app_compose.count('kafka_topics:')} service dependencies)"
    )


if __name__ == "__main__":
    main()

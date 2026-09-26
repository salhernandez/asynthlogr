#!/usr/bin/env bash
# Builds and runs the debian:bookworm-slim test image.
# Usage: tests/docker/run.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="asynthlogr-tests-debian-bookworm-slim"

docker build \
  -f "$REPO_ROOT/tests/docker/Dockerfile.debian-bookworm-slim" \
  -t "$IMAGE_TAG" \
  "$REPO_ROOT"

docker run --rm "$IMAGE_TAG"

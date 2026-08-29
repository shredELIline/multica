#!/usr/bin/env bash
# Shared provenance values for the alexey-cloud build/deploy wrappers.
# Sourced, never executed directly. Exports only non-secret build metadata.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

ALEXEY_CLOUD_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
ALEXEY_CLOUD_COMMIT="$(git rev-parse HEAD)"
ALEXEY_CLOUD_SHORT="$(git rev-parse --short=9 HEAD)"
# Nearest upstream release tag this branch is built on top of.
ALEXEY_CLOUD_UPSTREAM_BASE="$(git describe --tags --abbrev=0 2>/dev/null || echo unknown)"
ALEXEY_CLOUD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Human-readable version baked into the binaries and NEXT_PUBLIC_APP_VERSION.
ALEXEY_CLOUD_VERSION="${ALEXEY_CLOUD_UPSTREAM_BASE}+alexey-cloud.${ALEXEY_CLOUD_SHORT}"
# Immutable image tag. A caller may pin one explicitly — that is how a CI-built
# image is deployed (ALEXEY_CLOUD_TAG=<full-sha> deploy.sh) and how a rollback
# selects an older build. Otherwise it is derived from HEAD, and a dirty tree
# gets a suffix so an unreproducible build can never be mistaken for a clean one.
if [ -n "${ALEXEY_CLOUD_TAG:-}" ]; then
  :
elif [ -n "$(git status --porcelain)" ]; then
  ALEXEY_CLOUD_TAG="${ALEXEY_CLOUD_SHORT}-dirty"
else
  ALEXEY_CLOUD_TAG="${ALEXEY_CLOUD_SHORT}"
fi

ALEXEY_CLOUD_BACKEND_IMAGE="${ALEXEY_CLOUD_BACKEND_IMAGE:-ghcr.io/shredeliline/multica-backend}"
ALEXEY_CLOUD_WEB_IMAGE="${ALEXEY_CLOUD_WEB_IMAGE:-ghcr.io/shredeliline/multica-web}"

export ALEXEY_CLOUD_BRANCH ALEXEY_CLOUD_COMMIT ALEXEY_CLOUD_SHORT \
       ALEXEY_CLOUD_UPSTREAM_BASE ALEXEY_CLOUD_DATE ALEXEY_CLOUD_VERSION \
       ALEXEY_CLOUD_TAG ALEXEY_CLOUD_BACKEND_IMAGE ALEXEY_CLOUD_WEB_IMAGE

# Production runs digest-pinned GHCR images. This set contains no `build:`
# section at all, so a deploy physically cannot turn into a build.
COMPOSE_FILES=(-f docker-compose.selfhost.yml -f docker-compose.alexey-cloud.prod.yml)

# Building from source is a separate activity with its own override. Only
# build.sh uses this set.
COMPOSE_BUILD_FILES=(-f docker-compose.selfhost.yml -f docker-compose.alexey-cloud.yml)

#!/usr/bin/env bash
# Build the backend and web images for this deployment from the current
# checkout. Does not touch the running stack — see deploy.sh for that.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if [[ "$ALEXEY_CLOUD_TAG" == *-dirty ]]; then
  echo "WARNING: working tree is dirty; tagging images '$ALEXEY_CLOUD_TAG'." >&2
  echo "         Commit before building an image you intend to keep." >&2
fi

echo "==> Building from ${ALEXEY_CLOUD_BRANCH} @ ${ALEXEY_CLOUD_COMMIT}"
echo "    base:    ${ALEXEY_CLOUD_UPSTREAM_BASE}"
echo "    version: ${ALEXEY_CLOUD_VERSION}"
echo "    backend: ${ALEXEY_CLOUD_BACKEND_IMAGE}:${ALEXEY_CLOUD_TAG}"
echo "    web:     ${ALEXEY_CLOUD_WEB_IMAGE}:${ALEXEY_CLOUD_TAG}"

# Serial, not parallel: this VPS has 12 GB RAM and the Next.js build is the
# memory-hungry half. Two concurrent builds is how you meet the OOM killer.
docker compose "${COMPOSE_BUILD_FILES[@]}" build --parallel=1 "$@"

echo
echo "==> Built images"
docker image inspect "${ALEXEY_CLOUD_BACKEND_IMAGE}:${ALEXEY_CLOUD_TAG}" \
  "${ALEXEY_CLOUD_WEB_IMAGE}:${ALEXEY_CLOUD_TAG}" \
  --format '    {{index .RepoTags 0}}  id={{.Id}}  revision={{index .Config.Labels "org.opencontainers.image.revision"}}'

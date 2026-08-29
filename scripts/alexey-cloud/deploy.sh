#!/usr/bin/env bash
# Roll the running stack onto images already built by build.sh.
#
# Preserves: .env, the multica_pgdata and multica_backend_uploads volumes, and
# every existing container's data. Never brings the stack down with -v, never
# prunes, never deletes a volume.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

for img in "${ALEXEY_CLOUD_BACKEND_IMAGE}:${ALEXEY_CLOUD_TAG}" \
           "${ALEXEY_CLOUD_WEB_IMAGE}:${ALEXEY_CLOUD_TAG}"; do
  docker image inspect "$img" >/dev/null 2>&1 || {
    echo "ERROR: $img not built. Run scripts/alexey-cloud/build.sh first." >&2
    exit 1
  }
done

echo "==> Deploying ${ALEXEY_CLOUD_VERSION} (tag ${ALEXEY_CLOUD_TAG})"
# --no-build: deploy only what build.sh already produced, so a deploy can never
# silently become an unrecorded build.
docker compose "${COMPOSE_FILES[@]}" up -d --no-build

echo "==> Waiting for backend readiness"
for i in $(seq 1 60); do
  if curl -fsS -m 5 http://127.0.0.1:8080/readyz >/dev/null 2>&1; then
    echo "    ready after ${i}s"
    break
  fi
  sleep 1
  [ "$i" = 60 ] && { echo "ERROR: backend not ready after 60s" >&2; exit 1; }
done

exec "$(dirname "${BASH_SOURCE[0]}")/verify.sh"

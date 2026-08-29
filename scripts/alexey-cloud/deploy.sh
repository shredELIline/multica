#!/usr/bin/env bash
# Roll the running stack onto images already built by build.sh.
#
# Preserves: .env, the multica_pgdata and multica_backend_uploads volumes, and
# every existing container's data. Never brings the stack down with -v, never
# prunes, never deletes a volume.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# Both images must exist locally before anything is recreated. A CI-built tag
# is pulled on demand; a locally built one is expected to be there already.
for img in "${ALEXEY_CLOUD_BACKEND_IMAGE}:${ALEXEY_CLOUD_TAG}" \
           "${ALEXEY_CLOUD_WEB_IMAGE}:${ALEXEY_CLOUD_TAG}"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "==> $img not present locally, pulling"
    docker pull "$img" || {
      echo "ERROR: $img is neither built locally nor pullable." >&2
      echo "       Build it with scripts/alexey-cloud/build.sh, or set" >&2
      echo "       ALEXEY_CLOUD_TAG to a tag that exists in GHCR." >&2
      exit 1
    }
  fi
done

# Preflight: recreating a container makes it re-read .env. If the database's
# stored password has drifted from POSTGRES_PASSWORD, the old containers are
# the only place the working value still exists, and the failure only shows up
# after they are gone. Check while the stack is still up.
if docker compose "${COMPOSE_FILES[@]}" ps -q postgres | grep -q .; then
  if docker compose "${COMPOSE_FILES[@]}" exec -T postgres sh -c \
       'PGPASSWORD="$POSTGRES_PASSWORD" psql -h postgres -U "$POSTGRES_USER" \
          -d "$POSTGRES_DB" -tAc "select 1"' >/dev/null 2>&1; then
    echo "==> Preflight: database accepts the password in .env"
  else
    echo "ERROR: the database rejects POSTGRES_PASSWORD from .env." >&2
    echo "       Recreating the containers now would leave the backend unable to" >&2
    echo "       authenticate. Reconcile them first:" >&2
    echo "         scripts/alexey-cloud/sync-db-password.sh" >&2
    echo "       That sets the role password to the value already in .env. It" >&2
    echo "       touches no data and does not modify .env." >&2
    exit 1
  fi
fi

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

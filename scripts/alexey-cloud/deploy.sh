#!/usr/bin/env bash
# Roll the running stack onto the digest-pinned GHCR images declared in
# docker-compose.alexey-cloud.prod.yml.
#
# Production never builds. The production compose set contains no `build:`
# section, so a missing image is a hard failure, not a silent local compile.
#
# Preserves: .env, the multica_pgdata and multica_backend_uploads volumes, and
# all container data. Never brings the stack down with -v, never prunes, never
# deletes a volume.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

BACKUPS=/srv/alexey-cloud/backups/multica-migration
BASELINE_ENV="$BACKUPS/.env.baseline.20260829T121251Z"
RECORD="$BACKUPS/deployments.log"

echo "== preflight =="

# 1. Volumes must exist. Losing one is the only truly unrecoverable failure
#    here, so it is checked before anything is touched.
for v in multica_pgdata multica_backend_uploads; do
  docker volume inspect "$v" >/dev/null 2>&1 \
    || { echo "  FAIL volume $v is missing — refusing to deploy" >&2; exit 1; }
  echo "  ok   volume $v present"
done

# 2. .env integrity. Compared against the pre-migration backup, not enforced:
#    a deliberate configuration change is legitimate, an accidental rewrite is
#    not, and only the operator can tell them apart. Checksums only — never
#    contents.
if [ -f "$BASELINE_ENV" ]; then
  if cmp -s .env "$BASELINE_ENV"; then
    echo "  ok   .env identical to the current baseline"
  else
    echo "  WARN .env differs from $BASELINE_ENV"
    echo "       sha256 now:      $(sha256sum .env      | cut -c1-16)…"
    echo "       sha256 baseline: $(sha256sum "$BASELINE_ENV" | cut -c1-16)…"
    echo "       If this was intentional, take a fresh backup. If not, stop."
  fi
else
  echo "  WARN no .env baseline at $BASELINE_ENV"
fi

# 3. Database password preflight (DEC-011). A recreate makes containers re-read
#    .env; if the stored password has drifted, the working value dies with the
#    old container. Catch it while that container still exists.
if docker compose "${COMPOSE_FILES[@]}" ps -q postgres | grep -q .; then
  if docker compose "${COMPOSE_FILES[@]}" exec -T postgres sh -c \
       'PGPASSWORD="$POSTGRES_PASSWORD" psql -h postgres -U "$POSTGRES_USER" \
          -d "$POSTGRES_DB" -tAc "select 1"' >/dev/null 2>&1; then
    echo "  ok   database accepts the password in .env"
  else
    echo "  FAIL the database rejects POSTGRES_PASSWORD from .env." >&2
    echo "       Recreating now would leave the backend unable to authenticate." >&2
    echo "       Reconcile first:  scripts/alexey-cloud/sync-db-password.sh" >&2
    exit 1
  fi
else
  echo "  note postgres is not running; password preflight skipped"
fi

# 4. Record what is running, so a rollback target always exists on disk.
echo "== recording current state =="
{
  echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) pre-deploy ---"
  echo "checkout HEAD: $ALEXEY_CLOUD_COMMIT ($ALEXEY_CLOUD_BRANCH)"
  echo ".env sha256:   $(sha256sum .env | cut -d' ' -f1)"
  for svc in backend frontend postgres; do
    cid="$(docker compose "${COMPOSE_FILES[@]}" ps -q "$svc" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      echo "  $svc container=$(echo "$cid" | cut -c1-12) image=$(docker inspect "$cid" --format '{{.Image}}' | cut -c1-19) ref=$(docker inspect "$cid" --format '{{.Config.Image}}')"
    else
      echo "  $svc not running"
    fi
  done
  docker volume ls --format '  volume {{.Name}}' | grep multica
} | tee -a "$RECORD"
chmod 600 "$RECORD"

# 5. Fetch the pinned images. Anonymous — the packages are public and this host
#    holds no registry credentials.
echo "== images =="
mapfile -t IMAGES < <(docker compose "${COMPOSE_FILES[@]}" config --images | grep '@sha256:')
[ "${#IMAGES[@]}" -eq 2 ] \
  || { echo "  FAIL expected 2 digest-pinned images, found ${#IMAGES[@]}" >&2; exit 1; }
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "  ok   present  ${img##*/}"
  else
    echo "  ==>  pulling  ${img##*/}"
    docker pull -q "$img" >/dev/null \
      || { echo "  FAIL cannot pull $img" >&2; exit 1; }
  fi
done

echo "== deploying =="
# Extra arguments are forwarded to `up`, so a deliberate full recreation is
#   scripts/alexey-cloud/deploy.sh --force-recreate
# and still runs every preflight above rather than bypassing them.
docker compose "${COMPOSE_FILES[@]}" up -d --no-build "$@"

echo "== waiting for backend readiness =="
for i in $(seq 1 90); do
  if curl -fsS -m 5 http://127.0.0.1:8080/readyz >/dev/null 2>&1; then
    echo "  ready after ${i}s"
    break
  fi
  sleep 1
  [ "$i" = 90 ] && { echo "  ERROR backend not ready after 90s" >&2; exit 1; }
done

exec "$(dirname "${BASH_SOURCE[0]}")/verify.sh"

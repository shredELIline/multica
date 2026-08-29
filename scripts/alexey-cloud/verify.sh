#!/usr/bin/env bash
# Prove what is actually running: fork images, healthy backend, private root
# route. Read-only.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# env.sh turns on -e; this script must run every check, not stop at the first.
set +e

fail=0
check() { if [ "$1" = 0 ]; then echo "  ok   $2"; else echo "  FAIL $2"; fail=1; fi; }

# Every path the two Dockerfiles actually COPY. Derived from their COPY lines,
# not guessed: these are the only files whose contents can end up inside an
# image, so a commit that leaves all of them alone cannot have changed what was
# built.
BUILD_INPUTS=(
  Dockerfile Dockerfile.web .dockerignore
  server docker
  apps/web packages
  package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json .npmrc
  LICENSE NOTICE
)

# Does an image built at $1 still correspond to this checkout's source?
#
# Exactly HEAD is the easy yes, but it is not the normal case. Digest pinning
# makes HEAD structurally one commit *ahead* of the deployed revision: CI builds
# commit X, then the pin naming X's digest is committed as X+1. Demanding an
# exact match would therefore fail after every correct deploy. Same for a
# documentation edit.
#
# So: accept an ancestor of HEAD whose diff touches no build input, and reject
# anything else. An allowlist of real build inputs, rather than a denylist of
# paths assumed harmless — a new top-level file is then treated as suspicious by
# default instead of being silently ignored.
image_is_current() {
  local rev="$1"
  [ "$rev" = "$ALEXEY_CLOUD_COMMIT" ] && return 0
  git merge-base --is-ancestor "$rev" HEAD 2>/dev/null || return 1
  [ -z "$(git diff --name-only "$rev" HEAD -- "${BUILD_INPUTS[@]}")" ]
}

echo "== containers =="
docker compose "${COMPOSE_FILES[@]}" ps --format '  {{.Name}}  {{.Image}}  {{.Status}}'

echo "== image provenance =="
for svc in backend frontend; do
  cid="$(docker compose "${COMPOSE_FILES[@]}" ps -q "$svc")"
  [ -n "$cid" ] || { echo "  FAIL $svc has no container"; fail=1; continue; }
  img="$(docker inspect "$cid" --format '{{.Image}}')"
  ref="$(docker inspect "$cid" --format '{{.Config.Image}}')"
  case "$ref" in
    *@sha256:*) check 0 "$svc runs a digest-pinned image, not a mutable tag" ;;
    *)          check 1 "$svc runs a digest-pinned image (found tag ref: $ref)" ;;
  esac
  case "$ref" in
    ghcr.io/shredeliline/*) check 0 "$svc image comes from the fork's GHCR namespace" ;;
    *)                     check 1 "$svc image comes from the fork's GHCR namespace (found $ref)" ;;
  esac
  # The pinned digest must be the one the compose files declare, so that what
  # is running is what is committed — not whatever happened to be pulled.
  if docker compose "${COMPOSE_FILES[@]}" config --images 2>/dev/null | grep -qxF "$ref"; then
    check 0 "$svc digest matches the pin in docker-compose.alexey-cloud.prod.yml"
  else
    check 1 "$svc digest matches the pin in docker-compose.alexey-cloud.prod.yml"
  fi
  docker image inspect "$img" --format \
    "  $svc  id={{.Id}}
       repo={{index .RepoTags 0}}
       source={{index .Config.Labels \"org.opencontainers.image.source\"}}
       revision={{index .Config.Labels \"org.opencontainers.image.revision\"}}
       branch={{index .Config.Labels \"cloud.alexey.branch\"}}
       base={{index .Config.Labels \"cloud.alexey.upstream-base\"}}
       ref=$ref"
  rev="$(docker image inspect "$img" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  image_is_current "$rev"
  rc=$?
  if [ "$rc" = 0 ] && [ "$rev" != "$ALEXEY_CLOUD_COMMIT" ]; then
    check 0 "$svc image built from ${rev:0:9}; checkout is ahead but touches no build input"
  else
    check $rc "$svc image matches this checkout (HEAD $ALEXEY_CLOUD_SHORT)"
  fi
done

echo "== health =="
readyz="$(curl -fsS -m 10 http://127.0.0.1:8080/readyz || true)"
echo "  readyz: $readyz"
echo "  health: $(curl -fsS -m 10 http://127.0.0.1:8080/health || true)"
grep -q '"db":"ok"' <<<"$readyz"; check $? "database reachable"
grep -q '"migrations":"ok"' <<<"$readyz"; check $? "migrations applied"

echo "== private root route =="
root_code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:3000/)"
root_loc="$(curl -s -o /dev/null -w '%{redirect_url}' -m 10 http://127.0.0.1:3000/)"
echo "  GET /        -> $root_code $root_loc"
[ "$root_code" = 307 ] && [[ "$root_loc" == */login ]]; check $? "/ redirects logged-out visitors to /login"
login_code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:3000/login)"
echo "  GET /login   -> $login_code"
[ "$login_code" = 200 ]; check $? "/login serves the sign-in page"
home_code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:3000/homepage)"
echo "  GET /homepage-> $home_code"
[ "$home_code" = 200 ]; check $? "/homepage still serves the Multica landing page"

echo "== data volumes (must exist) =="
for v in multica_pgdata multica_backend_uploads; do
  docker volume inspect "$v" >/dev/null 2>&1; check $? "volume $v present"
done

echo
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"

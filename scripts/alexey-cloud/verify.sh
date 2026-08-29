#!/usr/bin/env bash
# Prove what is actually running: fork images, healthy backend, private root
# route. Read-only.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# env.sh turns on -e; this script must run every check, not stop at the first.
set +e

fail=0
check() { if [ "$1" = 0 ]; then echo "  ok   $2"; else echo "  FAIL $2"; fail=1; fi; }

echo "== containers =="
docker compose "${COMPOSE_FILES[@]}" ps --format '  {{.Name}}  {{.Image}}  {{.Status}}'

echo "== image provenance =="
for svc in backend frontend; do
  cid="$(docker compose "${COMPOSE_FILES[@]}" ps -q "$svc")"
  [ -n "$cid" ] || { echo "  FAIL $svc has no container"; fail=1; continue; }
  img="$(docker inspect "$cid" --format '{{.Image}}')"
  docker image inspect "$img" --format \
    "  $svc  id={{.Id}}
       repo={{index .RepoTags 0}}
       source={{index .Config.Labels \"org.opencontainers.image.source\"}}
       revision={{index .Config.Labels \"org.opencontainers.image.revision\"}}
       branch={{index .Config.Labels \"cloud.alexey.branch\"}}
       base={{index .Config.Labels \"cloud.alexey.upstream-base\"}}"
  rev="$(docker image inspect "$img" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [ "$rev" = "$ALEXEY_CLOUD_COMMIT" ]; check $? "$svc image was built from $ALEXEY_CLOUD_SHORT"
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

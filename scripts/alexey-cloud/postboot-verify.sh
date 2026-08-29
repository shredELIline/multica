#!/usr/bin/env bash
# Post-reboot readiness proof for alexey-cloud-01.
#
# Answers one question: did the box come back with Multica healthy and no
# manual repair? Read-only — starts nothing, changes nothing.
#
# Run it after a reboot, or before one to confirm the box is reboot-ready.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
set +e

fail=0
check() { if [ "$1" = 0 ]; then echo "  ok   $2"; else echo "  FAIL $2"; fail=1; fi; }

echo "== host =="
echo "  hostname: $(hostname)"
echo "  uptime:   $(uptime -p) (since $(uptime -s))"
echo "  kernel:   $(uname -r)"

echo "== services enabled at boot =="
for u in docker.service containerd.service tailscaled.service ufw.service fail2ban.service; do
  en="$(systemctl is-enabled "$u" 2>&1)"; ac="$(systemctl is-active "$u" 2>&1)"
  printf '  %-22s enabled=%-9s active=%s\n' "$u" "$en" "$ac"
  [ "$en" = enabled ] && [ "$ac" = active ]; check $? "$u enabled and active"
done

echo "== tailscale =="
state="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)"
echo "  BackendState: ${state:-<unavailable>}"
[ "$state" = Running ]; check $? "tailscale is up"

echo "== firewall =="
# `ufw status` needs root; the unit state is the unprivileged proxy for it.
# For the rule list run: sudo ufw status verbose
systemctl is-active ufw.service >/dev/null 2>&1; check $? "ufw active"
systemctl is-active fail2ban.service >/dev/null 2>&1; check $? "fail2ban active"

echo "== docker =="
docker info >/dev/null 2>&1; check $? "docker daemon responding"
echo "  server: $(docker info --format '{{.ServerVersion}}' 2>/dev/null)  containers running: $(docker info --format '{{.ContainersRunning}}' 2>/dev/null)"

echo "== compose stack =="
docker compose "${COMPOSE_FILES[@]}" ps --format '  {{.Name}}  {{.Status}}'
for svc in postgres backend frontend; do
  cid="$(docker compose "${COMPOSE_FILES[@]}" ps -q "$svc" 2>/dev/null)"
  [ -n "$cid" ] && [ "$(docker inspect "$cid" --format '{{.State.Running}}')" = true ]
  check $? "$svc container running"
  if [ -n "$cid" ]; then
    [ "$(docker inspect "$cid" --format '{{.HostConfig.RestartPolicy.Name}}')" = unless-stopped ]
    check $? "$svc restart policy is unless-stopped"
  fi
done

echo "== running image digests match the committed pin =="
for svc in backend frontend; do
  cid="$(docker compose "${COMPOSE_FILES[@]}" ps -q "$svc" 2>/dev/null)"
  ref="$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null)"
  echo "  $svc: $ref"
  docker compose "${COMPOSE_FILES[@]}" config --images 2>/dev/null | grep -qxF "$ref"
  check $? "$svc digest matches docker-compose.alexey-cloud.prod.yml"
done

echo "== application health =="
readyz="$(curl -fsS -m 15 http://127.0.0.1:8080/readyz 2>/dev/null)"
echo "  readyz: ${readyz:-<no response>}"
echo "  health: $(curl -fsS -m 15 http://127.0.0.1:8080/health 2>/dev/null)"
grep -q '"db":"ok"'         <<<"$readyz"; check $? "database reachable"
grep -q '"migrations":"ok"' <<<"$readyz"; check $? "migrations applied"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 15 http://127.0.0.1:3000/)"         = 307 ]; check $? "/ redirects to login"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 15 http://127.0.0.1:3000/login)"    = 200 ]; check $? "/login serves"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 15 http://127.0.0.1:3000/homepage)" = 200 ]; check $? "/homepage serves"

echo "== volumes =="
for v in multica_pgdata multica_backend_uploads; do
  docker volume inspect "$v" >/dev/null 2>&1; check $? "volume $v present"
done

echo "== data =="
counts="$(docker compose "${COMPOSE_FILES[@]}" exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select '"'"'migrations='"'"'||(select count(*) from schema_migrations)"' 2>/dev/null | tr -d '\r')"
echo "  $counts"
[ "$counts" = "migrations=469" ]; check $? "schema_migrations still 469 (pre-migration baseline)"

echo "== .env =="
cmp -s .env /srv/alexey-cloud/backups/multica-migration/.env.20260829T090145Z
check $? ".env identical to the migration baseline"

echo
[ "$fail" = 0 ] && echo "REBOOT READINESS: ALL CHECKS PASSED" || echo "REBOOT READINESS: SOME CHECKS FAILED"
exit "$fail"

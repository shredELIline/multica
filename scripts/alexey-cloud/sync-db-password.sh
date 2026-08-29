#!/usr/bin/env bash
# Set the PostgreSQL role's password to POSTGRES_PASSWORD from .env.
#
# Needed when the stored password has drifted from .env — typically because
# .env was regenerated after the cluster was initialised, while the running
# containers kept the original value baked into their environment. Nothing
# notices until a container is recreated, at which point the backend cannot
# authenticate and the original password is gone with the old container.
#
# This works regardless of the drift because pg_hba.conf trusts the local
# socket inside the container. It changes a credential, not data: no table is
# read, written, or dropped.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

docker compose "${COMPOSE_FILES[@]}" ps -q postgres | grep -q . || {
  echo "ERROR: the postgres container is not running." >&2
  exit 1
}

# The password is passed as a psql variable and quoted into SQL with %L, so it
# is never expanded onto a command line, into a log, or onto the terminal.
docker compose "${COMPOSE_FILES[@]}" exec -T postgres sh -s <<'EOS'
set -e
psql -U "$POSTGRES_USER" -d postgres -q -v ON_ERROR_STOP=1 \
     -v u="$POSTGRES_USER" -v p="$POSTGRES_PASSWORD" <<'SQL'
SELECT format('ALTER USER %I WITH PASSWORD %L', :'u', :'p') \gexec
SQL
PGPASSWORD="$POSTGRES_PASSWORD" psql -h postgres -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" -tAc "select 'verified over the scram path'"
EOS
echo "✓ database password now matches .env"

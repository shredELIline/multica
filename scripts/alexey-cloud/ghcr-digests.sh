#!/usr/bin/env bash
# Print the immutable GHCR digests for a given fork commit, for pasting into
# docker-compose.alexey-cloud.prod.yml.
#
# Resolves anonymously against the registry — the packages are public and this
# host holds no registry credentials.
#
# Usage: scripts/alexey-cloud/ghcr-digests.sh <full-40-char-commit-sha>
set -euo pipefail

REF="${1:-}"
[ -n "$REF" ] || { echo "usage: $0 <full-40-char-commit-sha|tag>" >&2; exit 1; }

for repo in shredeliline/multica-backend shredeliline/multica-web; do
  token="$(curl -fsS -m 20 "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" \
           | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
  digest="$(curl -fsS -m 20 -I -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
      "https://ghcr.io/v2/${repo}/manifests/${REF}" \
      | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')"
  [ -n "$digest" ] || { echo "ERROR: ${repo}:${REF} not found in GHCR" >&2; exit 1; }
  echo "ghcr.io/${repo}@${digest}"
done

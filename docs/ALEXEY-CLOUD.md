# alexey-cloud — Multica operations

Operating manual for the private Multica deployment on **alexey-cloud-01**.
Written for whoever is at the terminal next, including a future me who has
forgotten all of this.

Companion documents:
- `docs/ALEXEY-CLOUD-UPSTREAM.md` — consuming a new upstream release
- `docs/ALEXEY-CLOUD-LICENSE-NOTES.md` — what the Multica License permits here

---

## Architecture

```
        github.com/multica-ai/multica          (upstream — releases only)
                        |
                        | merge a release TAG, never main
                        v
        github.com/shredELIline/multica        (origin — canonical for this box)
                 main                          read-only mirror of upstream/main
                 alexey-cloud                  what actually gets built
                        |
          +-------------+--------------+
          |                            |
   GitHub Actions                 local build
   (ghcr.io/shredeliline/…)   scripts/alexey-cloud/build.sh
          |                            |
          +-------------+--------------+
                        v
                  alexey-cloud-01
        docker compose project "multica"
        backend :8080  frontend :3000   (both bound to 127.0.0.1)
        postgres (no host port at all)
        volumes: multica_pgdata, multica_backend_uploads
```

Reachable only over Tailscale. Nothing listens on a public interface: the app
ports are bound to `127.0.0.1` and PostgreSQL is not published to the host at
all. That is a licence boundary as much as a security one — see the licence
notes on why an instance open to outside users would need a commercial licence.

Multica stays a bounded application under `/srv/alexey-cloud/multica`. Future
personal-platform services (Telegram bot, task tracker, personal hub, agent
runtimes) belong in sibling directories under `/srv/alexey-cloud/` and should
talk to Multica over its HTTP API and webhooks. Do not add them to this fork:
every line committed here is a line that can conflict on the next upstream
merge, and the fork's value is that its diff against upstream stays tiny.

---

## Git remotes

```
origin     https://github.com/shredELIline/multica     (mine — canonical)
upstream   https://github.com/multica-ai/multica       (theirs — releases)
```

`upstream` fetches `refs/heads/main` and tags only; upstream's in-progress
feature branches are deliberately not mirrored.

`origin` is SSH, `upstream` is HTTPS. That split is deliberate: upstream is
public and only ever read, so it needs no credential at all.

Authentication is a dedicated key on this host — no personal key was copied
here:

```
~/.ssh/id_ed25519_github_alexey_cloud        (private — never leaves the box)
~/.ssh/id_ed25519_github_alexey_cloud.pub    (registered on GitHub)
~/.ssh/config                                 pins that key to github.com
```

It is registered as a **repository deploy key on shredELIline/multica with
write access**, not as an account-wide key. So it authenticates to that one
repository and nothing else — if this host is ever compromised, the blast
radius is this fork, not the whole GitHub account.

The practical tell, and the expected output of the identity check:

```bash
$ ssh -T git@github.com
Hi shredELIline/multica! You've successfully authenticated, but GitHub does not provide shell access.
```

`Hi shredELIline/multica!` (repo) rather than `Hi shredELIline!` (account) is
correct here. Exit status 1 from that command is also normal — GitHub gives no
shell. A repo-scoped key cannot push to any other repository, which is the
point; do not "fix" that by promoting it to an account key.

## Branch model

| Branch | Role | Rule |
| --- | --- | --- |
| `main` | mirror of `upstream/main` | never commit to it; fast-forward only |
| `alexey-cloud` | the deployed branch | based on release tags; our patches live here |
| `integration/vX.Y.Z` | throwaway | where an upstream merge is tested, then deleted |

`alexey-cloud` is based on **`v0.4.36`** — the exact release the official image
was built from when this box was migrated, so the first fork deployment
differed from what it replaced by our patch and nothing else.

Everything this fork owns:

```bash
BASE=$(git describe --tags --abbrev=0 --match 'v*' alexey-cloud)   # e.g. v0.4.36
git log  --oneline "$BASE..alexey-cloud"
git diff --stat      "$BASE..alexey-cloud"
```

Diff against the **base tag**, not against `main`. `main` mirrors
`upstream/main`, which runs ahead of the newest release, so
`git diff main..alexey-cloud` also reverses whatever upstream has merged since
the tag and wildly overstates what this fork changed. As of v0.4.36 the honest
number is 11 files, and exactly one of them (`apps/web/proxy.ts`) is a file
upstream also owns.

Never rebase `alexey-cloud`, never force push. The deployment is identified by
commit SHA; rewriting history would orphan running images.

## What this fork changes

One behavioural patch, in `apps/web/proxy.ts`: on any origin that is not an
official Multica marketing host, `/` resolves to the application — the last
workspace if the cookie names one, otherwise `/login` — instead of serving the
public marketing landing.

The landing page itself is untouched and still served at **`/homepage`**. No
Multica branding, product name, or copyright notice is removed from the
interface; keeping it that way is a licence obligation, not a preference.

Everything else we add lives in files upstream does not have:

```
docker-compose.alexey-cloud.yml
scripts/alexey-cloud/{env,build,deploy,verify}.sh
.github/workflows/alexey-cloud-images.yml
docs/ALEXEY-CLOUD*.md
```

## How to build

```bash
cd /srv/alexey-cloud/multica
git switch alexey-cloud
scripts/alexey-cloud/build.sh
```

Builds `ghcr.io/shredeliline/multica-backend:<short-sha>` and
`…/multica-web:<short-sha>` from the current checkout, stamped with OCI labels
naming the fork, the revision, and the upstream release the branch sits on.

A dirty working tree is tagged `<short-sha>-dirty` and warns. That is a smoke
test, never a release.

Builds run one at a time (`--parallel=1`). The box has 12 GB of RAM and the
Next.js build is the memory-hungry half; two at once is how you meet the OOM
killer. There is 4 GB of swap, but it is a safety net, not a budget.

For reference, upstream's own commands still work and are untouched:
`make selfhost` pulls the official images; `make selfhost-build` builds from
the checkout as `multica-backend:dev` / `multica-web:dev`. Neither knows about
the fork's tags or labels, so use the scripts above for anything you intend to
deploy.

## How production is deployed

```bash
scripts/alexey-cloud/deploy.sh
```

It refuses to run unless both images exist (pulling them if the tag is in
GHCR), rolls the stack with `docker compose up -d --no-build`, waits for
`/readyz`, then runs `verify.sh` and exits non-zero if anything fails.

`--no-build` is deliberate: a deploy can never quietly become an unrecorded
build.

Named volumes and `.env` are carried through untouched — compose recreates only
the containers whose definition changed, and the project name stays `multica`,
so `multica_pgdata` and `multica_backend_uploads` are reattached as-is.

### Deploying a CI-built image

Once `.github/workflows/alexey-cloud-images.yml` has published a commit:

```bash
ALEXEY_CLOUD_TAG=<full-40-char-commit-sha> scripts/alexey-cloud/deploy.sh
```

CI tags images with the full commit SHA (plus a moving `alexey-cloud` tag, and
the tag name for `ac-v*` releases). Deploy by SHA — the moving tag is for
convenience, not for production.

This is the target steady state: the VPS pulls immutable images and stops being
a build machine.

## How to check health

```bash
scripts/alexey-cloud/verify.sh          # everything below, with pass/fail
```

Individually:

```bash
docker compose -f docker-compose.selfhost.yml ps
curl -fsS http://127.0.0.1:8080/readyz   # {"status":"ok","checks":{"db":"ok","migrations":"ok"}}
curl -fsS http://127.0.0.1:8080/health   # reports the commit the backend was built from
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://127.0.0.1:3000/        # 307 → /login
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/login                   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/homepage                # 200
```

`readyz` reporting `"migrations":"ok"` is the signal that the schema matches the
running binary.

## How custom images are identified

Provenance is asserted, not assumed. Every fork-built image carries labels
baked in at build time from `git rev-parse HEAD`:

```bash
docker inspect "$(docker compose -f docker-compose.selfhost.yml ps -q backend)" \
  --format '{{.Image}}' | xargs docker image inspect --format \
  '{{index .Config.Labels "org.opencontainers.image.source"}} {{index .Config.Labels "org.opencontainers.image.revision"}}'
```

An official `ghcr.io/multica-ai/*` image has no such label, so `verify.sh`
fails against it rather than passing silently. The backend independently
reports its build commit at `/health`.

## How to inspect logs

```bash
CF="-f docker-compose.selfhost.yml -f docker-compose.alexey-cloud.yml"
docker compose $CF logs -f --tail=200 backend
docker compose $CF logs -f --tail=200 frontend
docker compose $CF logs --tail=200 postgres
docker compose $CF logs --since=15m           # everything, recent
```

Backend startup logs are where migration failures surface.

## How to preserve `.env`

`.env` holds generated secrets — `JWT_SECRET`, `POSTGRES_PASSWORD`,
`MULTICA_VCS_SECRET_KEY`, and the `DATABASE_URL` that embeds the password. It
is gitignored upstream and must stay that way.

- Never delete, overwrite, print, commit, or upload it.
- Never re-run `make selfhost` / `make selfhost-build` expecting them to leave
  it alone if it is missing — both **generate a fresh one** from
  `.env.example`, and a new `POSTGRES_PASSWORD` against an existing volume
  locks you out of your own database.
- Back it up before any migration:

```bash
B=/srv/alexey-cloud/backups/multica-migration
TS=$(date -u +%Y%m%dT%H%M%SZ)
cp -a .env "$B/.env.$TS" && chmod 600 "$B/.env.$TS"
```

Backups live at `/srv/alexey-cloud/backups/multica-migration/` (mode 700,
files mode 600), outside the repository so they cannot be committed.

## The `.env` / database password trap

Read this before any upgrade. It cost the first deployment ten minutes of
downtime and it will recur.

`docker compose up` **recreates a container whenever its definition changes —
including when the set of `-f` files changes**, because compose records that
list in a `com.docker.compose.project.config_files` label. Recreating a
container makes it re-read `.env`.

PostgreSQL, by contrast, only reads `POSTGRES_PASSWORD` at `initdb` time. After
that the password lives in the volume. So if `.env` is ever regenerated after
the cluster was created — a second `make selfhost`, a re-provision, anything
that rewrites the file — the two silently diverge, and **nothing notices**: the
running containers still hold the original value in their baked environment and
keep working indefinitely.

The bill arrives at the next recreate. The new backend reads the current `.env`,
the database still expects the original, and you get:

```
FATAL: password authentication failed for user "multica" (SQLSTATE 28P01)
```

The original password is now unrecoverable — it existed only in the container
that was just replaced. This is not caused by the fork; rolling back to the
official images recreates the backend from the same `.env` and fails
identically.

**The repair**, which works because `pg_hba.conf` trusts the local socket
inside the container:

```bash
scripts/alexey-cloud/sync-db-password.sh
```

It sets the role's password to the value already in `.env`. It touches no data
and does not modify `.env`. The backend clears its restart loop on the next
retry.

`deploy.sh` now runs this as a preflight and refuses to recreate anything if
the database rejects the `.env` password — so the failure surfaces while the
old containers, and the working credential inside them, still exist.

## How to restore the database

Take a dump (credentials are read inside the container and never printed):

```bash
docker compose -f docker-compose.selfhost.yml exec -T postgres \
  sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > /srv/alexey-cloud/backups/multica-migration/multica-db-$(date -u +%Y%m%dT%H%M%SZ).dump
```

Restore into the running database. Stop the backend first so nothing writes
during the restore:

```bash
CF="-f docker-compose.selfhost.yml -f docker-compose.alexey-cloud.yml"
docker compose $CF stop backend frontend

docker compose $CF exec -T postgres sh -c \
  'cat > /tmp/restore.dump && pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
     --clean --if-exists --no-owner /tmp/restore.dump; rc=$?; rm -f /tmp/restore.dump; exit $rc' \
  < /srv/alexey-cloud/backups/multica-migration/multica-db-<TIMESTAMP>.dump

docker compose $CF start backend frontend
curl -fsS http://127.0.0.1:8080/readyz
```

Inspect a dump without restoring it:

```bash
docker compose -f docker-compose.selfhost.yml exec -T postgres sh -c \
  'cat > /tmp/x.dump && pg_restore -l /tmp/x.dump; rm -f /tmp/x.dump' < <dumpfile> | head
```

`--clean --if-exists` drops and recreates the objects in the dump. It does not
touch the volume, and it does not remove the database.

## How to roll back

The official images are still on disk and were never overwritten — the fork
uses different image names entirely — so rolling back is a compose flag, not a
rebuild.

**Rollback to the previous fork build** (the normal case — a bad patch):

```bash
git switch alexey-cloud
git log --oneline -5                                  # pick the last good commit
ALEXEY_CLOUD_TAG=<previous-short-sha> scripts/alexey-cloud/deploy.sh
```

If that image is gone, check out the commit and rebuild:
`git switch --detach <sha> && scripts/alexey-cloud/build.sh && scripts/alexey-cloud/deploy.sh`.

**Rollback to the official upstream images** (the escape hatch — the fork build
is broken and you want the box working now):

```bash
cd /srv/alexey-cloud/multica
docker compose -f docker-compose.selfhost.yml up -d      # no fork override
docker compose -f docker-compose.selfhost.yml ps
curl -fsS http://127.0.0.1:8080/readyz
```

Dropping the `-f docker-compose.alexey-cloud.yml` override is the whole
rollback: the base file resolves back to
`ghcr.io/multica-ai/multica-{backend,web}:latest`. To pin the exact images that
were running before the migration rather than whatever `:latest` points at now,
use the digests recorded in
`/srv/alexey-cloud/backups/multica-migration/state-*.txt`:

```bash
docker run --rm ghcr.io/multica-ai/multica-backend@sha256:<digest> --version   # sanity
MULTICA_IMAGE_TAG=<tag> docker compose -f docker-compose.selfhost.yml up -d
```

**What rollback does not undo:** database migrations. They run on backend
startup and are forward-only. Rolling an image back to a version older than the
schema can fail at `/readyz`. That is what the pre-update `pg_dump` is for —
restore it, then start the older image.

Both rollback paths reuse the same `.env`, the same containers' volumes, and
the same database. Nothing is deleted.

## What MUST NOT be deleted

| Thing | Why |
| --- | --- |
| `/srv/alexey-cloud/multica/.env` | generated secrets; losing `POSTGRES_PASSWORD` locks you out of the volume |
| volume `multica_pgdata` | the entire database |
| volume `multica_backend_uploads` | uploaded attachments |
| `/srv/alexey-cloud/backups/multica-migration/` | `.env` copies, DB dumps, pre-migration image digests |
| `~/.ssh/id_ed25519_github_alexey_cloud*` | this host's GitHub identity |
| official `ghcr.io/multica-ai/*` images | the rollback escape hatch |

Commands that must never be run in this directory:

```
docker compose ... down -v          # deletes the named volumes
docker volume rm multica_pgdata     # deletes the database
docker system prune --volumes       # deletes the database
docker system prune -a              # deletes the rollback images
rm .env / cp .env.example .env      # destroys the secrets
```

`scripts/alexey-cloud/*.sh` contain none of these, by design.

## Firewall and exposure

Do not add host port bindings on `0.0.0.0`, do not publish PostgreSQL, do not
expose the Docker API, and do not remove UFW rules or open SSH to the public
Internet. Administration is over Tailscale. If Multica ever needs to be
reachable from another device, put it behind Tailscale — not behind a public
port.

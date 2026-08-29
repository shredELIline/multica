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

**Not needed for production.** Production pulls from GHCR; this is for local
iteration and for the pre-merge test in the upstream-update procedure.

```bash
cd /srv/alexey-cloud/multica
git switch alexey-cloud
scripts/alexey-cloud/build.sh
```

Builds `ghcr.io/shredeliline/multica-backend:<short-sha>` and
`…/multica-web:<short-sha>` from the current checkout via
`docker-compose.alexey-cloud.yml`, stamped with OCI labels naming the fork, the
revision, and the upstream release the branch sits on. These local tags are
distinct from the digests production runs, so a local build never disturbs the
deployed images.

A dirty working tree is tagged `<short-sha>-dirty` and warns. That is a smoke
test, never a release.

Builds run one at a time (`--parallel=1`). The box has 12 GB of RAM and the
Next.js build is the memory-hungry half; two at once is how you meet the OOM
killer. There is 4 GB of swap, but it is a safety net, not a budget.

For reference, upstream's own commands still work and are untouched:
`make selfhost` pulls the official images; `make selfhost-build` builds from
the checkout as `multica-backend:dev` / `multica-web:dev`. Neither knows about
the fork's digests or labels, so never use them to deploy.

## How production is deployed

**Production runs immutable, digest-pinned images pulled from GHCR. The VPS is
not a build machine.**

```bash
scripts/alexey-cloud/deploy.sh
```

That is the whole production deployment command. It:

1. refuses to continue if either data volume is missing;
2. compares `.env` against the migration baseline and warns on any difference;
3. runs the database password preflight (see the trap section below) and
   **aborts before recreating anything** if the stored password has drifted;
4. appends the current container IDs, image IDs, volumes and `.env` checksum to
   `/srv/alexey-cloud/backups/multica-migration/deployments.log`, so a rollback
   target always exists on disk;
5. pulls the pinned digests if they are not already local;
6. runs `docker compose up -d --no-build`, waits for `/readyz`, then execs
   `verify.sh` and exits non-zero if any check fails.

Extra arguments are forwarded to `up`, so a deliberate full recreation is
`scripts/alexey-cloud/deploy.sh --force-recreate` and still runs every preflight
rather than bypassing them.

### Why digests, not tags

`docker-compose.alexey-cloud.prod.yml` pins both services by **digest**:

```yaml
image: ghcr.io/shredeliline/multica-backend@sha256:93cd4ffc…
```

A tag is a mutable pointer — anyone who can push to the registry can repoint
`alexey-cloud`, or even a commit-SHA tag, at different bytes. A digest names
the bytes themselves. Pinning it in a committed file means the deployed
artefact is recorded in version control instead of inferred from the registry's
current state, and `verify.sh` asserts that what is running is exactly what is
committed.

That file also contains **no `build:` section at all**, which is what makes
"production never builds" structural rather than a convention: a missing image
is a hard failure, not a silent local compile. Building is a separate activity
with its own override (`docker-compose.alexey-cloud.yml`) used only by
`build.sh`.

Both refs are overridable, so a rollback needs no edit:

```bash
ALEXEY_CLOUD_BACKEND_REF=ghcr.io/shredeliline/multica-backend@sha256:… \
ALEXEY_CLOUD_WEB_REF=ghcr.io/shredeliline/multica-web@sha256:…       \
  scripts/alexey-cloud/deploy.sh
```

### Moving the pin to a new build

CI publishes on every push to `alexey-cloud`. To adopt a new build:

```bash
git push origin alexey-cloud                 # CI builds and pushes to GHCR
# wait for the run to go green, then:
scripts/alexey-cloud/ghcr-digests.sh <full-40-char-commit-sha>
# paste both lines into docker-compose.alexey-cloud.prod.yml, commit, then:
scripts/alexey-cloud/deploy.sh
```

`ghcr-digests.sh` resolves the digests anonymously against the registry. Note
that CI tags images with the **full 40-character** commit SHA — the 9-character
short form used for local builds does not exist in GHCR.

### GHCR access

Both packages are public, so the VPS pulls anonymously and holds **no registry
credentials at all** — there is no `~/.docker/config.json` on this host and no
personal access token to rotate or leak. Keep it that way: if the packages ever
go private, prefer making them public again over putting a token on the box.

Named volumes and `.env` are carried through every deploy untouched. The
compose project name stays `multica`, so `multica_pgdata` and
`multica_backend_uploads` are reattached as-is.

## How to check health

```bash
scripts/alexey-cloud/verify.sh          # deployment: images, provenance, routes
scripts/alexey-cloud/postboot-verify.sh # the above plus host, boot units, data
```

`postboot-verify.sh` is the one to run after a reboot — or before one, to
confirm the box is reboot-ready. It is read-only: it starts nothing and repairs
nothing.

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

### Reboot drill

The stack is expected to come back from a cold boot with no human action beyond
reconnecting. That is not a claim, it has been exercised:

| Drill | Result |
| --- | --- |
| 2026-08-29T10:46:54Z (boot), verified 10:49 UTC | passed, no manual repair |

What came back on its own: SSH over Tailscale (no console needed),
`docker`, `containerd`, `tailscaled`, `fail2ban`, the UFW ruleset, all three
containers under `restart: unless-stopped`, and the application on the
digest-pinned GHCR images. The backend reported `started_at`
2026-08-29T10:47:26Z — roughly 30 seconds after boot.
`postboot-verify.sh` printed `REBOOT READINESS: ALL CHECKS PASSED`; no
container, volume or database repair was needed, and no digest moved.

Re-run the drill after anything that changes boot-time behaviour: a kernel or
Docker upgrade, a change to restart policies, a new unit, or a firewall change.
The procedure is `sudo reboot`, wait ~30-60s, reconnect over Tailscale, then:

```bash
scripts/alexey-cloud/postboot-verify.sh
```

If the backend is unhealthy after a boot, check the database password preflight
first (`scripts/alexey-cloud/sync-db-password.sh`) — see the `.env` trap below.

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

`verify.sh` additionally asserts that each running container is referenced by
**digest** rather than a mutable tag, that the digest sits in the fork's GHCR
namespace, and that it is byte-for-byte the digest committed in
`docker-compose.alexey-cloud.prod.yml`. Together those turn "we think the fork
is running" into something checkable in one command.

### Version metadata, and why CI fetches upstream tags

Beyond provenance, each image carries descriptive build metadata:

| Label / build arg | Example | Source |
| --- | --- | --- |
| `cloud.alexey.upstream-base` | `v0.4.36` | `git describe --tags --abbrev=0 --match 'v*'` |
| `cloud.alexey.describe` | `v0.4.36-7-gfbef34b5d` | `git describe --tags --long --match 'v*' --abbrev=9` |
| `org.opencontainers.image.version`, `VERSION`, `NEXT_PUBLIC_APP_VERSION` | `v0.4.36+alexey-cloud.fbef34b5d` | `<base>+alexey-cloud.<short-sha>` |

`--match 'v*'` matters: the repository also carries `desktop-v*` tags, and
without it the nearest tag can be a desktop release rather than the platform
release this branch is based on.

Read them off a running image with:

```bash
docker image inspect ghcr.io/shredeliline/multica-backend@sha256:<digest> \
  --format '{{json .Config.Labels}}' | python3 -m json.tool
```

GitHub does not copy a parent repository's tags into a fork, and this fork
deliberately has none of its own (see below), so a plain CI checkout has
nothing for `git describe` to resolve. `.github/workflows/alexey-cloud-images.yml`
therefore fetches upstream's release tags into the CI workspace before
resolving the version:

```yaml
git -c http.https://github.com/.extraheader= \
    fetch --no-tags --force "$UPSTREAM_REPO" 'refs/tags/v*:refs/tags/v*'
```

Three properties of that line are deliberate. The refspec is `v*` only, so
`desktop-v*` never enters the workspace. The empty `extraheader` drops the
credential `actions/checkout` configures for github.com, so no token is
presented to a repository outside this fork — upstream is public and the fetch
is anonymous. And it writes to the CI workspace only.

**Never push upstream's `v*` tags to the fork instead.** The fork inherits
upstream's `release.yml`, which triggers on `v*.*.*`; ~100 tags would fire ~100
Release runs, each invoking goreleaser, publishing binaries to the fork's
Releases, and pushing images into this GHCR namespace. See DEC-014.

If the tag fetch fails, the workflow fails. It does not fall back to `unknown`:
an image whose metadata lies about its base is worse than an image that was
never built, because the pin that follows is chosen from that metadata.

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

`docker compose up` recreates a container whenever its **resolved
configuration** changes, and recreating a container makes it re-read `.env`.

Do not try to predict which containers that will hit. Observed on this box: the
first fork deploy recreated all three containers including postgres, while the
later GHCR deploy recreated only backend and frontend. Assume any deploy — and
certainly `--force-recreate`, a host reboot, or a `docker compose up` after an
upstream change — can recreate postgres.

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

Three targets, cheapest first. None of them rebuilds, and none touches a volume.

**1. Roll back to an earlier fork build (the normal case — a bad change).**
Every deploy appends the refs it replaced to
`/srv/alexey-cloud/backups/multica-migration/deployments.log`, so the previous
digests are on disk:

```bash
tail -20 /srv/alexey-cloud/backups/multica-migration/deployments.log
ALEXEY_CLOUD_BACKEND_REF=ghcr.io/shredeliline/multica-backend@sha256:<old> \
ALEXEY_CLOUD_WEB_REF=ghcr.io/shredeliline/multica-web@sha256:<old>       \
  scripts/alexey-cloud/deploy.sh
```

Then edit `docker-compose.alexey-cloud.prod.yml` back to those digests and
commit, so the committed pin and the running stack agree again — otherwise the
next plain `deploy.sh` rolls you forward into the bad build.

Older digests are also resolvable from the registry at any time:
`scripts/alexey-cloud/ghcr-digests.sh <full-40-char-commit-sha>`.

**2. Roll back to the locally built images** (still on disk, different tags, so
they were never overwritten):

```bash
ALEXEY_CLOUD_BACKEND_REF=ghcr.io/shredeliline/multica-backend:c4c275544 \
ALEXEY_CLOUD_WEB_REF=ghcr.io/shredeliline/multica-web:c4c275544         \
  scripts/alexey-cloud/deploy.sh
```

**3. Roll back to the official upstream images (the escape hatch — the fork
build is broken and you want the box working now).** Drop the fork override
entirely; the base file resolves back to
`ghcr.io/multica-ai/multica-{backend,web}:latest`, which are still on disk at
the IDs recorded in `state-*.txt`:

```bash
cd /srv/alexey-cloud/multica
docker compose -f docker-compose.selfhost.yml up -d
curl -fsS http://127.0.0.1:8080/readyz
```

Note this path skips `deploy.sh` and therefore skips the database password
preflight. Run `scripts/alexey-cloud/postboot-verify.sh` afterwards, and if the
backend cannot authenticate, `scripts/alexey-cloud/sync-db-password.sh`.

**What rollback does not undo:** database migrations. They run on backend
startup and are forward-only. Rolling an image back to a version older than the
schema can fail at `/readyz`. That is what the pre-update `pg_dump` is for —
restore it, then start the older image.

All three paths reuse the same `.env`, the same volumes, and the same database.
Nothing is deleted.

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

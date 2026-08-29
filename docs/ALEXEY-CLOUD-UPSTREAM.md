# Consuming a new upstream Multica release

Governing rule: **upstream never reaches production by accident.** `main` is a
read-only mirror, `alexey-cloud` is what gets built, and nothing moves between
them without a deliberate merge.

```
upstream tag vX.Y.Z
        |
   review changelog
        |
        v
integration/vX.Y.Z   <- merge the tag into a throwaway branch first
        |
   build + test
        |
        v
   alexey-cloud      <- fast-forward only after the integration branch is green
        |
   build + deploy + verify
        |
        v
   production        (rollback ready — see docs/ALEXEY-CLOUD.md)
```

## The upstream model, as observed

- Upstream tags releases `vX.Y.Z` on `main`. As of this writing the newest is
  `v0.4.36` (2026-08-28); releases land every one to three days.
- The official `ghcr.io/multica-ai/multica-*:latest` images track release tags.
  The image running before this migration reported commit `c1a61e1e8`, which
  `git describe --tags --contains` resolves to `v0.4.36^0`.
- `upstream/main` runs ahead of the newest tag. **Do not build from it.**
- The public changelog lives in `apps/web/features/landing/i18n/en.ts` and is
  rendered at `/changelog`.

`git fetch upstream` here fetches `main` and tags only, by design (DEC-007).

## 0. Snapshot before you start

```bash
cd /srv/alexey-cloud/multica
TS=$(date -u +%Y%m%dT%H%M%SZ)
B=/srv/alexey-cloud/backups/multica-migration
cp -a .env "$B/.env.$TS" && chmod 600 "$B/.env.$TS"
docker compose -f docker-compose.selfhost.yml exec -T postgres \
  sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$B/multica-db-$TS.dump"
chmod 600 "$B/multica-db-$TS.dump"
# Note the currently deployed tag so you can roll straight back to it.
docker compose -f docker-compose.selfhost.yml ps --format '{{.Name}} {{.Image}}'
```

Migrations run automatically on backend start and are not reversed by rolling
an image back, so the dump is the only real undo for a schema change.

## 1. Fetch and review

```bash
git fetch upstream --tags
git tag --list 'v*' | sort -V | tail -5

CURRENT=$(git describe --tags --abbrev=0 --match 'v*' alexey-cloud)   # e.g. v0.4.36
NEXT=v0.4.37                                                          # pick deliberately

# What changed, and did any of it touch what we patched?
git log --oneline "$CURRENT..$NEXT"
git diff --stat "$CURRENT..$NEXT" -- apps/web/proxy.ts apps/web/proxy.test.ts \
    Dockerfile Dockerfile.web docker-compose.selfhost.yml server/migrations LICENSE
```

Read the changelog diff before anything else:

```bash
git diff "$CURRENT..$NEXT" -- apps/web/features/landing/i18n/en.ts | head -80
```

Check `LICENSE` specifically — condition 2(a) lets the producer change the
terms. If it moved, re-read `docs/ALEXEY-CLOUD-LICENSE-NOTES.md` against the
new text before deploying.

## 2. Merge into a throwaway integration branch

Never merge straight into `alexey-cloud`. If the merge turns out badly you want
to delete a branch, not undo a merge on the branch production builds from.

```bash
git switch -c "integration/$NEXT" alexey-cloud
git merge "$NEXT"
```

Expect conflicts only in `apps/web/proxy.ts` — it is the sole upstream file
this fork modifies. Everything else we own lives in files upstream does not
have (DEC-003).

Resolving a `proxy.ts` conflict: keep upstream's version of the function and
re-apply our root-path rule on top of it. Our rule is one `if` block; the
intent is "on a non-marketing host, `/` resolves to the app". Re-read
`git log --oneline -- apps/web/proxy.ts` on `alexey-cloud` for the reasoning
before choosing a resolution.

```bash
git add apps/web/proxy.ts
git merge --continue
```

## 3. Build and test the integration branch

```bash
scripts/alexey-cloud/build.sh
```

Then run the web test suite inside the image you just built — it is the same
build, so this costs one container start and no rebuild:

```bash
source scripts/alexey-cloud/env.sh
docker build -f Dockerfile.web --target builder \
  -t multica-web-builder:"$ALEXEY_CLOUD_TAG" .          # cached, seconds
docker run --rm multica-web-builder:"$ALEXEY_CLOUD_TAG" \
  pnpm --filter @multica/web test
```

At minimum, `apps/web/proxy.test.ts` must pass — that is the suite that pins
our one behavioural change.

## 4. Promote, deploy, verify

Only once the integration branch is green:

```bash
git switch alexey-cloud
git merge --ff-only "integration/$NEXT"
git branch -d "integration/$NEXT"

scripts/alexey-cloud/build.sh     # re-tags at the promoted commit
scripts/alexey-cloud/deploy.sh    # rolls the stack, then runs verify.sh
```

`deploy.sh` exits non-zero if `verify.sh` fails. If it does, roll back
immediately using the procedure in `docs/ALEXEY-CLOUD.md`; do not debug a
half-deployed stack in production.

## 5. Push, let CI build, then move the production pin

Production does not run what you built locally in step 3 — that build was the
test. Production runs the CI-built image, pinned by digest.

```bash
git push origin alexey-cloud
```

That triggers `.github/workflows/alexey-cloud-images.yml`. When the run is
green:

```bash
scripts/alexey-cloud/ghcr-digests.sh "$(git rev-parse HEAD)"
```

Paste both lines into `docker-compose.alexey-cloud.prod.yml`, update the
`revision` / `base` comment above them, commit, push, and deploy:

```bash
scripts/alexey-cloud/deploy.sh
```

The deploy runs the volume, `.env` and database-password preflights, records
the outgoing digests to `deployments.log` for rollback, and verifies the result.

Do not deploy by tag. CI publishes a moving `alexey-cloud` tag for convenience;
production pins digests so that what runs is what is committed.

## Keeping the `main` mirror current

`main` carries no local commits, so this is always a fast-forward. If it ever
refuses, something has been committed to `main` by mistake — investigate, do
not force.

```bash
git fetch upstream
git switch main
git merge --ff-only upstream/main
git switch alexey-cloud
```

## What not to do

- Do not `git rebase` `alexey-cloud`, and do not `git push --force` anything.
  The branch is published and the deployment is identified by its commit SHA.
- Do not merge `upstream/main` into `alexey-cloud`. Merge a **tag**.
- Do not deploy a build from a dirty working tree. `build.sh` tags those
  `<sha>-dirty` precisely so they are obvious; treat that tag as a smoke test,
  never as a release.
- Do not skip the pre-update database dump because "it is only a patch
  release". Migrations are forward-only.

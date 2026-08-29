# Licence notes for the alexey-cloud fork

Scope: what the Multica License permits and forbids for **this** deployment —
a private, single-operator self-host on alexey-cloud-01, reachable only over
Tailscale, with a public source fork at `shredELIline/multica`.

This is an operator's reading of the licence text in `LICENSE` at tag
`v0.4.36`, written to make the practical constraints checkable. It is not legal
advice. Re-read `LICENSE` after every upstream merge — condition 2(a) lets the
producer change the terms.

## What the licence is

`LICENSE` is the **Multica License**: Part I (additional conditions) plus
Part II (the complete, unmodified Apache License 2.0), which together form one
set of terms. Part I controls where the two conflict (condition 3(c)). Neither
part grants anything on its own (preamble, condition 3(a)).

## Private self-hosting — permitted, no commercial licence needed

Condition 1(a) restricts *hosted or embedded* use: providing Multica as a
service to **third parties**, or embedding it in a product sold or distributed
to third parties. It states explicitly that "internal use within a single
organization (including multiple workspaces) does not require a commercial
licence".

Running this instance for yourself over Tailscale is internal use. It is not a
hosted service.

The line to watch: the restriction applies "whether or not you charge for it",
and "a publicly accessible instance operated for users outside your own
organization requires a commercial licence even when it is offered free of
charge". So:

- Adding your own accounts, workspaces, and agents — fine.
- Opening the instance to people outside your organisation, even free, even
  invite-only, even without ads — that is the thing that requires a commercial
  licence from Multica.

Keeping the deployment bound to `127.0.0.1` and reachable only via Tailscale is
therefore a licence boundary as well as a security one.

## Modifying the source — permitted

Nothing in Part I restricts modification for your own use. Part II section 4
governs modification and redistribution: keep the licence, state significant
changes, retain notices.

## Maintaining a public GitHub fork — permitted

Condition 1(a) says so directly: "Making the source code available, including
publishing the source code of a fork in a public repository, is not itself a
hosted service and does not require a commercial license."

Two obligations attach when you publish the fork:

1. **Ship the whole licence file.** Condition 3(d): "If you redistribute
   Multica or a derivative work of it, you must deliver this complete file.
   Delivering Part II alone does not satisfy the Multica License." Do not
   replace `LICENSE` with a plain Apache-2.0 file, and do not delete `NOTICE`.
2. **Conditions 1(b) and 1(c) still apply** to the published fork, and
   publishing source does not grant anyone who clones it the right to operate a
   hosted service — condition 1(a) says "each operator must obtain its own
   commercial license".

## UI branding — the binding constraint

Condition 1(b): without a **written branding waiver** from the producer, you
may not remove or modify:

- the Multica logo,
- the Multica product name,
- the copyright and attribution information displayed by a Multica user
  interface.

"Multica user interface" is defined broadly and deliberately: anything derived
in whole or substantial part from the UI code here, explicitly naming
`apps/web/`, `apps/desktop/`, `apps/mobile/`, `packages/views/`, and
`packages/ui/`, plus the `ghcr.io/multica-ai/multica-web` container image and
any compiled desktop or mobile build. The enumeration is "illustrative rather
than exhaustive", and coverage survives modifying, moving, renaming, or
extracting the code into another package or repository.

That last clause matters for a fork: rebuilding the web image under
`ghcr.io/shredeliline/multica-web` does not take it outside the definition.

### Applied to the change this fork actually makes

The only customisation is in `apps/web/proxy.ts`: `/` now resolves to the app
rather than to the marketing landing.

This does not engage condition 1(b). The landing component
(`MulticaLanding`) is untouched, and `/homepage` — an upstream route that
already existed at `v0.4.36` — still renders it in full, logo, product name,
footer copyright and all. The application shell, the login page, and the
`LICENSE` and `NOTICE` files copied into the image by `Dockerfile.web` are all
unchanged. Nothing displayed by the interface has been removed or modified;
only which route the operator lands on first has.

**Rules this fork holds itself to:**

- Do not delete or edit the landing route group, the logo assets, the product
  name in the UI, or any footer/about copyright text.
- Do not remove the `COPY LICENSE NOTICE ./` lines from `Dockerfile` or
  `Dockerfile.web`.
- Keep `/homepage` reachable and returning 200. `scripts/alexey-cloud/verify.sh`
  asserts this on every deploy, so a future change that breaks it fails the
  deploy rather than passing quietly.
- If a branding change is ever genuinely wanted, obtain a written branding
  waiver first. Condition 1(d) is explicit that a waiver cannot be inferred
  from the producer's "silence, review, or acceptance of your contributions",
  and that a commercial licence does not imply a branding waiver.

## Attribution when running without the UI

Condition 1(c) applies if you redistribute or operate something built on the
backend, daemon, or CLI **without** a Multica user interface: retain all
copyright, patent, trademark and attribution notices and the NOTICE file, and
state in user-facing documentation that the product is built on Multica, with a
link to `https://github.com/multica-ai/multica`.

Relevant to Phase 18: a future Telegram bot or personal hub that talks to the
Multica API is your own separate program, not a redistribution of Multica, so
1(c) is not triggered by merely calling the API. It would be triggered if you
ever ship or operate the Multica backend/daemon/CLI itself as part of something
you distribute. Keeping integrations outside this repository, talking over the
API, keeps that question from arising.

## Contributing back

Condition 2: contributions are submitted under the Multica License as a whole,
may be used commercially by the producer, and the producer may make the licence
stricter or more relaxed. Worth knowing before opening a PR upstream; it does
not affect private use.

## Quick reference

| Action | Allowed? |
| --- | --- |
| Run privately for yourself / your org | Yes, no commercial licence |
| Modify the source for your own instance | Yes |
| Publish the fork's source publicly | Yes, ship the complete `LICENSE` + `NOTICE` |
| Open the instance to outside users, even free | No — needs a commercial licence |
| Embed Multica in something you sell | No — needs a commercial licence |
| Remove/alter Multica logo, name, or UI copyright | No — needs a written branding waiver |
| Change which route `/` serves | Yes — navigation, not branding |
| Run backend/CLI only, redistributed | Yes, with condition 1(c) attribution |

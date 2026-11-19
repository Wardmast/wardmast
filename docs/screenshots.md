# Before/after UI screenshots: operator guide

Arbiter captures before/after screenshots of a UI change, shows them to the reviewer, and
posts them inline in the PR/MR description. The design and the rejected alternatives are in
[design/ui-screenshot-capture.md](design/ui-screenshot-capture.md); this page is what an
operator needs to turn it on and what it does and does not protect.

## How it works (as shipped)

1. A repo with a `worker.repos.<repo>.screenshots` block is "screenshot-enabled". A repo
   without one is untouched.
2. The worker declares routes in `.arbiter/screenshots.json` (gitignored, worker-local), or
   declares a `skip` with a reason.
3. **Before a reviewer is dispatched** (after the CI wait) the ReviewGate runs the capture on
   the **Arbiter host**: it `git archive`s the merge-base and the head, boots the app once
   from each (one after the other), shoots every declared route with headless Chromium, and
   pairs the images. A diff that does not touch `ui_paths` skips the capture.
4. Outcome routing: pairs (or a declared skip) go into the reviewer's brief; a *worker
   fault* (`manifest_missing`, `manifest_invalid`, `route_error`) is sent back to the worker
   to fix the plan; an *infrastructure fault* (boot, checkout, diff, budget, browser) parks
   `screenshot_capture_failed` for the coordinator and neither loops the worker nor
   dispatches a reviewer.
5. Images are hosted per forge (below) and rendered in a `## Screenshots` section of the
   PR/MR description, kept between marker comments so a worker's later `pr_body` edit does
   not drop it. Images are also stored as ticket attachments (shown on the dashboard).

## Enabling it for a repo

Set `worker.repos.<repo>.screenshots` (workspace default: `worker.screenshots`). Every key is
documented in `Wardmast.Tasks.Workspace.ConfigSchema` (`workspace_config_schema`). Minimum:

```json
{
  "ui_paths": ["lib/my_app_web/**", "assets/**"],
  "start_cmd": "mix phx.server",
  "setup_cmd": "mix deps.get && mix ecto.setup"
}
```

`start_cmd`, `setup_cmd` and the ready check fall back to the repo's `preview` settings when
unset. `base_url` must be loopback and `env` may not carry a proxy variable or a non-loopback
URL; the config is rejected otherwise. `enabled: false` turns the feature off.

**Chromium.** The shooter uses `$ARB_CHROME`, else `chromium` on `PATH`, on the host that
runs the gate. Install it there; capture fails with a browser fault otherwise.

## Per-forge setup

### GitHub

GitHub has no PR image-upload API, so images are committed to an orphan branch
(`arbiter-assets` by default, `hosting.github.branch`) through the Git Data API: one commit
per capture set, no clone, `[skip ci]` in the message. The description references them by
commit-pinned `https://<host>/<owner>/<repo>/blob/<sha>/…?raw=true` URLs (GitHub Enterprise
Server works: the host comes from the merger's base URL).

* The token Arbiter uses needs **contents: write** on the repo.
* **Branch protection.** `arbiter-assets` is machine-written and never merged. Exempt it from
  rulesets or protection that require PRs, reviews or status checks on every branch, and do
  not require signed commits there. The ref update is a plain non-forced move; if it is
  refused, hosting fails and the failure is recorded rather than posting broken images.
* Readers see the images only if they can read the repo (the URL is served with their
  session). They do not render in notification emails or link unfurls.
* That a pinned `?raw=true` URL renders in a **private** repo's PR description is the widely
  used pattern but has **not been verified** by Arbiter (design §12 R1). Check it once on a
  real private repo before relying on it.

### GitLab

Images go through the project uploads API (`POST /projects/:id/uploads`); the returned
project-relative markdown renders inline in the MR description. No branch is created and the
branch-protection note does not apply. The token needs permission to upload (Developer or
higher on the project). Arbiter does not delete GitLab uploads.

## Public repos: opt-in

Images in a public repo are world-readable and effectively permanent. Hosting **fails closed**:
if the repo is `public`, or its visibility cannot be read, nothing is posted unless
`hosting.public_repo_ok: true` is set for that repo. `private` and `internal` repos post.
Set it once, deliberately, only when your seeds are fixture data.

## Sandbox / host-mode caveat

The capture runs **on the host**, in the Arbiter server's context, not in a podman pod or
bwrap sandbox, and it is not placed on remote nodes. Consequences:

* There is **no network isolation**. The app boots with a scrubbed environment (only `PATH`,
  `HOME`, `LANG`, `TMPDIR`, the config's `env` and the port variable) but is not firewalled:
  a `start_cmd` or `.env`-style file that points at a real database can reach it if the host
  can. Point `setup_cmd`/`seed_cmd` at a throwaway database in `{{scratch}}`.
* Chromium runs with `--no-sandbox` because it is already inside an untrusted-input boot.
* A repo whose workers run in podman still captures on the host after the worker's PR
  branch is fetched; the host needs the repo's toolchain installed, and the worker image's
  toolchain is not used.
* The pod-based, network-less design (design §2, option C) is **not implemented**.

## Data safety: what is and is not enforced

Enforced today:

* Environment built from nothing; the operator's `DATABASE_URL`, forge/provider credentials
  and proxies are not inherited.
* Config validation (loopback `base_url`, no proxy/foreign-URL `env`).
* Only Arbiter uploads, using the merger's credential; the worker never holds it. Public
  repos fail closed (above). Public paste hosts and gists are never used.

Not enforced (configurable keys exist, but no runtime check ships): the `fixture_check`
marker probe and the DOM text scan that withholds shots containing emails, secrets or
`deny_patterns`. Do not rely on them. There is no pixel redaction. Seed fixtures yourself
and treat every screenshot as readable by everyone who can read the repo.

Size limits (`screenshots.limits`): 20 shots, 40 images, 2 MiB per image, 25 MiB per capture,
600 s setup, 120 s seed, 30 s per shot, 1200 s total (max 3600). Ticket attachments are
capped at 100 MiB per ticket and pruned 90 days after the ticket closes (the row stays,
marked pruned). Assets-branch history keeps the blobs, so old PR images keep rendering.

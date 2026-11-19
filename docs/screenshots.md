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
   the **Arbiter host**: it `git archive`s the merge-base and the head and boots the app once
   from each (one after the other), every command inside the **capture sandbox** (below: no
   network, an allowlisted filesystem). Each boot first gets its own fresh **services**
   (a database, an object store: podman containers with no network, `screenshots.services`)
   and, with `deps.mix`, its Mix dependencies from an **offline cache** built from the default
   branch's lockfile. It shoots every declared route with headless Chromium (sandboxed too) and
   pairs the images. A diff that does not touch `ui_paths` skips the capture.
4. Outcome routing: pairs (or a declared skip) go into the reviewer's brief; a *worker
   fault* (`manifest_missing`, `manifest_invalid`, `route_error`) is sent back to the worker
   to fix the plan; an *infrastructure fault* (boot, a service that did not come up, the deps
   cache, checkout, diff, budget, browser) parks `screenshot_capture_failed` for the coordinator
   and neither loops the worker nor dispatches a reviewer. A host that cannot sandbox the
   capture, and a change that edits `mix.lock` while `deps.mix` is on, are *skips*: the reviewer
   is told why there are no screenshots.
5. Images are hosted per forge (below) and rendered in a `## Screenshots` section of the
   PR/MR description, kept between marker comments so a worker's later `pr_body` edit does
   not drop it. Images are also stored as ticket attachments (shown on the dashboard).

Every outcome is written to `capture.json` in the capture's output directory
(`$TMPDIR/arbiter-review-screenshots/<task>/<head>/`): `state` (`ok`, `skipped`, `failed`),
`skip_kind` (`no_sandbox`, `plan_skip`, `deps_changed`) with `skip`, or `failure` (`code`,
`message`, `role`, `detail`).

## Enabling it for a repo

Set `worker.repos.<repo>.screenshots` (workspace default: `worker.screenshots`). Every key is
documented in `Wardmast.Tasks.Workspace.ConfigSchema` (`workspace_config_schema`). Minimum, for
an app that needs nothing but its own checkout:

```json
{
  "ui_paths": ["lib/my_app_web/**", "assets/**"],
  "start_cmd": "mix phx.server",
  "setup_cmd": "mix ecto.setup"
}
```

`start_cmd`, `setup_cmd` and the ready check fall back to the repo's `preview` settings when
unset. `base_url` must be loopback and `env` may not carry a proxy variable or a non-loopback
URL; the config is rejected otherwise. `enabled: false` turns the feature off.

`setup_cmd` runs with **no network**, so it cannot `mix deps.get` or download asset tools on its
own: turn on the offline deps cache (`"deps": {"mix": true}`, below) or list a dependency
cache under `sandbox.readonly_paths`. A database or object store comes from `services`. A full
DB-backed example is at the end of this page.

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

## The capture sandbox

The capture runs **on the Arbiter host** (not in a podman pod, not on remote nodes), with the
host's toolchain, but nothing it boots runs as the host: every setup, seed and start command,
and the browser, runs in a **bubblewrap sandbox** (bd-bhrsdv):

* **No network.** Its own network namespace, with only its own `lo`: the host's loopback (the
  coordinator on `:4848`, a database, other workers' servers) is an empty port and every other
  address has no route. A `.env` that points at a real database reaches nothing.
* **An allowlisted filesystem.** `/usr`, `/bin`, `/sbin`, `/lib*` and `/etc` read-only, a
  private `/tmp`, `/run` and `/var/tmp`, the boot's checkout and scratch writable, and nothing
  else: no home directory, no host `/tmp`, no runtime sockets. The server's own secrets and
  trees are masked even inside a listed path.
* **`sandbox.readonly_paths`** shows more of the host, read-only: a toolchain outside the
  system dirs (`~/.local/share/mise`, `~/.asdf`) or a dependency cache. Absolute or `~/` paths,
  never the home directory itself or above.
* **An environment built from nothing**: `PATH`, `HOME` (in the boot's scratch), `LANG`,
  `TMPDIR` (the scratch), `TZ`, the config's `env`, the port variable, and the deps cache's
  variables when it is on. The operator's `DATABASE_URL`, credentials and proxies are never
  inherited.
* **The browser** runs in a sandbox of its own that can reach only the app.

It needs `bwrap`, `perl` and `socat` (`perl`, `socat` and `sh` inside the system dirs). A host
without a working sandbox **skips** the capture (`skip_kind: no_sandbox`, "capture needs a
sandbox: …"); it never runs it unsandboxed.

## Services (`screenshots.services`)

A map of name -> service. For **every boot** (the merge-base boot, the head boot, and a boot
for a named seed) Wardmast starts each service as a fresh, uniquely named podman container
(`arb-cap-<role>-<token>-<name>`), waits until it is ready, runs the app's commands, and
removes the containers again. The before and after boots never share one, so each starts from
an empty database.

| key | |
|---|---|
| `image` | required. Pin a digest (`…@sha256:…`) or a tag you chose. Pulled if missing (`--pull=missing`); pre-pull it (`podman pull`) to keep the first capture fast |
| `port` | required, 1024-65535, outside `port_range`: where the service listens **inside its container**, and where the app reaches it: **`127.0.0.1:<port>` inside the sandbox** |
| `env` | literal strings for the container (no `{{placeholders}}`; fixture credentials only) |
| `command` | argv after the image (replaces its `CMD`) |
| `ready` | `{"cmd": [argv]}` (run in the container with `podman exec` until it exits 0) or `{"tcp": true}` (the port accepts a connection; the default), plus `timeout_seconds` (default 60, max 600) |
| `socket` | optional: a path under `/run/` or `/tmp/` of the sandbox where the service **also** shows as a Unix socket (e.g. `/run/postgresql/.s.PGSQL.5432`, so `PGHOST=/run/postgresql` works) |

**How the app reaches it, and nothing else.** Each container runs with `--network none` (only
its own `lo`), no published port, nothing of the host mounted, `no-new-privileges` and a short
capability list. Wardmast reaches it through its own namespace: a `socat` that `nsenter` puts in
the container's network namespace listens on a Unix socket on the host (a fresh `0700` directory
under the socket root) and connects to `127.0.0.1:<port>` inside the container. That socket is
shown read-only inside the app's sandbox, where a relay listens on `127.0.0.1:<port>`. The app
cannot reach podman, the host's loopback, another container or the service by any other route,
and the service itself has no way out either (which matters: a Postgres superuser can run
programs in its container). The browser never sees a service.

**Failure is visible.** A service that cannot start, exits, or is not ready in time fails the
boot: `boot_failed` with the service, the reason and the tail of its `podman logs`, in
`capture.json` and in the coordinator's escalation. Nothing of the app runs then, and nothing
ever runs unsandboxed instead.

**Removal on every path.** The boot removes its containers on success, on a boot, shot or
budget failure and on a crash. If the capture task is killed, or the server shuts down,
`Wardmast.Screenshots.Capture.Services.Reaper` removes them; at boot it removes those of a server
that died hard (containers labelled `arbiter.capture-service=<server pid>` whose server is gone).

Requirements: rootless or rootful `podman`, `nsenter` (util-linux) and `socat`; `setpriv`
(util-linux, optional) makes each bridge die with the server. Each service lives in its own
network namespace, so two services cannot talk to each other.

## The offline deps cache (`screenshots.deps`)

`"deps": {"mix": true}` gives every boot its Mix dependencies with no network:

* **Trusted lockfile only.** The cache is built from a `mix.lock` the **default branch** has
  had (`merge.base` of the workspace, else `main`): the merge-base's own, when the merge-base is
  on the default branch, else the default branch tip's when it is the same file. A head that
  edits, adds or deletes `mix.lock` is **skipped** (`skip_kind: deps_changed`, with the reason):
  the head's own `mix.exs` and lockfile never run with a network. The reviewer is told why.
* **Built once per lockfile and toolchain**, under `<scratch_root>/capture-deps/<lock>-<toolchain>`
  (the toolchain is what `elixir` reports inside the sandbox, so a new Elixir/OTP misses it).
  The seed runs in the default branch's `git archive`, in the same sandbox **with the network
  on** (trusted code only), with the server's proxy variables: `mix local.hex`/`local.rebar`
  when the lock needs them, `mix deps.get`, `mix deps.compile` (which fetches precompiled NIFs,
  `elixir_make`/`rustler_precompiled`, into the cache), and `mix esbuild.install` /
  `tailwind.install` when those deps are present. It takes up to `limits.setup_seconds`, and a
  failure is `deps_failed` (an infrastructure fault) with the output. Caches unused for 14
  days are pruned.
* **Read-only in every boot**, wired through the environment (`env` may not set these while
  `deps.mix` is on):

  | variable | value |
  |---|---|
  | `MIX_DEPS_PATH` | the cached `deps/` |
  | `MIX_HOME`, `HEX_HOME` | the cache's Hex and rebar3 |
  | `HEX_OFFLINE` | `1` |
  | `ELIXIR_MAKE_CACHE_DIR`, `RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH` | the precompiled NIFs |
  | `MIX_ESBUILD_PATH`, `MIX_TAILWIND_PATH` | the installed binaries, when present |

  The binaries are also linked at `_build/esbuild-<target>` / `_build/tailwind-<target>` in the
  checkout, where a stock Phoenix config looks for them; a config that reads
  `MIX_ESBUILD_PATH` works too. `mix deps.get` in `setup_cmd` is harmless (it finds everything
  fetched); `mix compile` builds into the checkout's own `_build`.

Not covered: npm packages (a `npm ci` in `setup_cmd` has no network; vendor them or list a
`node_modules` cache under `readonly_paths`), dependencies fetched over SSH or from a private
Hex organisation (the seed has no credentials), and a dependency that writes into its own
source directory while compiling (the cache is read-only).

## What a start script can rely on

A repo script (`start_cmd`, `setup_cmd`) runs inside the sandbox and can count on this, and
should not start podman, `socat` bridges or its own `bwrap` (none of them is reachable there):

* no network: only `127.0.0.1` inside the sandbox, which is not the host's;
* each service on `127.0.0.1:<port>` (its `port`), and at its `socket` path when one is set,
  ready before `setup_cmd` runs, empty for this boot;
* the app's own port in the port variable (`PORT` by default), from `port_range`;
* `HOME` and `TMPDIR` in the boot's scratch (`{{scratch}}`), the checkout as the working
  directory (`{{checkout}}`), `{{role}}` = `before` or `after`;
* with `deps.mix`: `HEX_OFFLINE=1` and `MIX_DEPS_PATH` set (a script can test for them to skip
  its own fetching), the cached esbuild/tailwind in `_build/`.

## A DB-backed example

A Phoenix app on PostGIS and an S3-compatible store (SILO), with its toolchain under mise:

<!-- db-backed-example (validated by config_test.exs) -->
```json
{
  "ui_paths": ["lib/my_app_web/**", "assets/**"],
  "setup_cmd": "mix ecto.setup",
  "seed_cmd": "mix run priv/repo/screenshot_seeds.exs",
  "start_cmd": "mix phx.server",
  "env": {
    "DATABASE_URL": "ecto://postgres:postgres@127.0.0.1:5432/my_app_dev",
    "S3_ENDPOINT": "http://127.0.0.1:9000",
    "AWS_ACCESS_KEY_ID": "minioadmin",
    "AWS_SECRET_ACCESS_KEY": "minioadmin",
    "SECRET_KEY_BASE": "screenshot-only-not-a-secret-screenshot-only-not-a-secret-000000",
    "PHX_HOST": "127.0.0.1"
  },
  "services": {
    "postgres": {
      "image": "docker.io/postgis/postgis:16-3.4",
      "port": 5432,
      "env": {
        "POSTGRES_USER": "postgres",
        "POSTGRES_PASSWORD": "postgres",
        "POSTGRES_DB": "my_app_dev"
      },
      "command": ["postgres", "-c", "fsync=off", "-c", "listen_addresses=127.0.0.1"],
      "ready": {"cmd": ["pg_isready", "-h", "127.0.0.1", "-U", "postgres"], "timeout_seconds": 90},
      "socket": "/run/postgresql/.s.PGSQL.5432"
    },
    "s3": {
      "image": "docker.io/pgsty/silo",
      "port": 9000,
      "env": {"MINIO_ROOT_USER": "minioadmin", "MINIO_ROOT_PASSWORD": "minioadmin"},
      "command": ["silo", "server", "/data", "--address", "127.0.0.1:9000"],
      "ready": {"tcp": true, "timeout_seconds": 60}
    }
  },
  "deps": {"mix": true},
  "sandbox": {"readonly_paths": ["~/.local/share/mise"]},
  "limits": {"budget_seconds": 1800}
}
```

Pin the two images by digest once you have chosen them (`podman pull`, then
`podman image inspect --format '{{.Digest}}'`). The app's database is created by `setup_cmd`
inside a Postgres that exists only for that boot, so the before and after boots never see each
other's data, and nothing is left afterwards.

## Data safety: what is and is not enforced

Enforced today:

* The capture sandbox: no network (no host loopback, no external host), no host files beyond the
  system directories and the listed read-only paths, and no capture at all on a host that
  cannot sandbox it.
* Services run with no network, are reachable only through their declared endpoints inside the
  sandbox, start empty for every boot and are removed after it.
* Dependencies are fetched only from a default-branch lockfile; a change's own `mix.exs` never
  runs with a network.
* Environment built from nothing; the operator's `DATABASE_URL`, forge/provider credentials
  and proxies are not inherited.
* Config validation (loopback `base_url`, no proxy/foreign-URL `env`, service keys).
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

# Before/after UI screenshots on every UI change: where and how Arbiter captures them

**Task:** bd-3kmz8c (decision, GitHub #1322) · **Epic:** bd-1wpc2h ·
**Builds on:** [podman worker containers](podman-worker-containers.md),
[remote workers](remote-workers.md), [app preview](../app-preview.md),
[visual-baseline refresh](../visual-baseline-refresh.md),
[worker security](../worker-security.md) · **Status:** proposed 2026-11-19; **partly superseded.** A host-side capture
run by the ReviewGate shipped instead of the pod pass (§2 and §11 record what shipped).
Operator guide: [screenshots.md](../screenshots.md).

**Operator requirement (2026-11-19).** The before/after screenshots render **inline in the
PR/MR description itself on both forges**. The ticket attachment and the dashboard are
*in addition to* the PR/MR, never instead of it. That requirement drives §7 (hosting) and
§8 (how the description is composed); every other section serves it.

## 1. Decisions in one screen

| # | Question | Decision | Main rejected alternative |
|---|---|---|---|
| D1 | Where capture runs | A new **capture pass**: Arbiter-run, no LLM, in a fresh **podman pod** (the repo's worker image + a pinned Chromium sidecar), placed like the other passes (`prefer_remote` honoured, falls back to the primary), after the PR exists | Inside the worker's own container; a CI job |
| D2 | Getting the "before" | Two **sequential** boots in one pod, each from a `git archive` of its commit (merge-base, then head), each with its **own fresh database** built from scratch (setup, migrate, seed) | Two concurrent boots; reusing one DB across both commits |
| D3 | Worker → Arbiter contract | `.arbiter/screenshots.json` (schema §5): a declarative list of shots, each with a path, viewports, themes and a few **declarative steps** (no code, no commands). Ingested at `arb done`, stored in the DB, never committed | A Playwright script the worker writes; deriving routes from the diff |
| D4 | Per-repo config | `worker.repos.<repo>.screenshots` (schema §6), merged over `worker.screenshots`, inheriting `start_cmd`/`setup_cmd` from `preview` when unset | A new top-level section unrelated to `preview` |
| D5 | Image hosting | GitLab: **uploads API** (`POST /projects/:id/uploads`). GitHub: an **orphan assets branch** in the same repo, one commit per capture set, images referenced by commit-SHA-pinned `github.com/…/blob/<sha>/…?raw=true` URLs | Arbiter-hosted URL, release assets, hidden ref, committing into the PR branch |
| D6 | Data safety | **Structural** isolation first (no network, throwaway DB built in the pod, scrubbed env, no credentials), then a config validator, a fixture marker probe, a **DOM text scan that withholds** a flagged shot, and a host-only upload path | A prompt rule telling the worker to use fixtures |
| D7 | Size and retention | ≤ 2 MiB/image, ≤ 40 images/capture, ≤ 24 MiB/capture, ≤ 100 MiB/ticket; blobs on disk, content-addressed; pruned 90 days after close; global 5 GiB quota | Blobs in SQLite; unbounded keep |

Three findings from the code shaped these and are easy to miss:

1. **`SyncPrBody` replaces the whole description.** `Wardmast.Tasks.Issue.Changes.SyncPrBody`
   pushes `pr_body` to the forge on every change, with no read-modify-write. A screenshots
   section stored *in* the PR description would be wiped by the next worker `pr_body`
   update. The section therefore lives in its own record and is **composed in** at every
   write ([§8](#8-composing-the-pr-description)).
2. **The dashboard is loopback-only by design** (`docs/remote-access.md`). An
   "Arbiter-hosted" image URL cannot be reached by a PR reader. This kills the simplest
   GitHub option before any other consideration.
3. **`.arbiter/` is gitignored in this repo and is worker-local scratch everywhere.** A
   worker-authored `.arbiter/screenshots.json` cannot be assumed to be pushed, and must
   not be allowed to land in the target repo's history by accident.

## 2. Where capture runs (D1)

### Options

| Option | For | Against |
|---|---|---|
| **A. Inside the worker's container after the worker finishes** | Toolchain, deps cache and services already there | The container is the *agent's*: provider credentials, the Wardmast bridge, ticket egress grants, a writable worktree with the agent's uncommitted state. A capture there is not reproducible (the "before" needs a clean merge-base tree, which the agent's checkout is not) and mixes an untrusted-input app boot with a live agent. The pod is also torn down at exit, so on a cluster there is nothing left to run in; keeping it alive pins a slot while it waits for PR creation |
| **B. A CI job whose artifacts Arbiter reads** (as visual-baselines does) | Real CI environment; no capture code in Arbiter | Needs a job *in every repo's pipeline*, and the GitHub App token this deployment uses cannot create or edit `.github/workflows/`, so Arbiter could not even add it. CI runs the head only: the before shot needs a second boot at the merge-base, i.e. a second job plus matrix wiring per repo. Latency is the CI queue; artifacts expire (visual-baselines already documents that); fork/merged-results pipelines run at a different SHA. The worker→Arbiter contract (§5) would have to be a CI input. Visual-baselines can lean on CI because the repo *already* has a Playwright suite; capture-of-arbitrary-routes does not |
| **C. A separate Arbiter-run pass in a fresh pod (chosen)** | Clean, reproducible, credential-free sandbox; placeable on a node or the primary; same image as the repo's worker, so the app boots with the toolchain it was built for; idempotent, so loss is retried | New pass kind and a Chromium sidecar image |
| D. On the primary host with the existing `preview` machinery | Already boots the app, allocates ports (`preview_leases`), reads the same `command`/`setup` | Runs on the host with the host's toolchain, not the repo's worker image, and **needs the toolchain installed on the primary** (remote nodes only ever run podman, so the primary may have none). No network isolation: a mis-pointed `DATABASE_URL` reaches whatever the host can reach. The cluster does not help |

### What shipped, and what is superseded

> **Superseded / deferred.** The pod-based `:capture_pass` below (option C, the N2 ticket) was
> **not built**. What shipped is a **host-side capture gated by the ReviewGate**
> (`Screenshots.Capture` + `Worker.ReviewGate.ScreenshotGate`): it runs on the Arbiter host
> before a reviewer is dispatched, boots the app at the merge-base and the head in turn
> (`Booter.Command`, scrubbed env, no network isolation), shoots with host Chromium
> (`$ARB_CHROME` or `chromium` on `PATH`, `--no-sandbox`), and routes the result as described
> under "Implemented" below. It does not use `Nodes.Placement`/`PassPlacement`, a podman pod,
> the `arbiter-capture` sidecar, debounce, or a merge wait. (`screenshot_captures`, supersession,
> the re-capture skip and `max_captures_per_ticket` *were* built later; see "Capture lifecycle"
> below.)
> The pod design stays as the deferred route if network isolation is wanted; the
> operator-facing trade-offs are in [screenshots.md](../screenshots.md).

The text below up to "Implemented" is the **original proposal**.

### Decision

A **capture pass** (`:capture_pass`), the fourth pass kind beside `:review_fix_round`,
`:fix_pass` and `:conflict_pass` (`Wardmast.Worker.PassPlacement`). It is Arbiter-driven,
runs no agent, and needs no provider account.

* **Placement.** It goes through the same two gates as the other passes
  (`PassPlacement.place/2`, `Nodes.LocalCapacity.gate/2`): `prefer_remote` runs it on a node
  with headroom, otherwise on the primary; `remote_only` holds it (held, never failed, no
  attempt spent); `local_only` keeps it local. `Nodes.Placement.eligible/1` must admit the new
  kind (today it admits only the three commit-writing passes, and only for Claude).
  Unlike those passes it **writes no commits** and needs no home clone seeding by `git
  push`/`--force-with-lease`: its inputs are two source trees (§4).
* **Podman only in v1.** The pass needs a network namespace it controls and a place to
  put Chromium. Remote nodes already run only podman-sandboxed runs. A repo whose runs use
  bwrap or no sandbox gets `skipped: capture needs the podman sandbox` on the PR and the
  ticket, which is honest and visible. Host-mode capture with `screenshots.browser_path` is a follow-up.
* **The pod.** `podman pod create --network none` (the `TestServices` pattern: members
  share one network namespace whose only interface is `lo`). Members:
  1. the **repo's worker image** (`Image.ensure/3`) running the runner script;
  2. the pinned **capture sidecar** (`arbiter-capture` image: Chromium + `playwright-core`
     + the `arb-capture` runner), driven over CDP on `127.0.0.1`;
  3. the repo's **test services** pod members (Postgres, object store) when the repo defines
     them, so a DB-backed app has a database with no network.

  A sidecar, not Chromium in every repo image: it keeps repo images small and Node-free,
  and (more importantly) before and after shots come from *one* browser build and one font
  set, so a diff is the app's and not the renderer's. Rejected: Chromium in each worker
  image (the existing sibling ticket's wording), which multiplies image size by repos and
  makes rendering depend on each repo's `apt` state.
* **Exits.** None except the egress proxy's **baseline** allow-list (hex/npm registries etc.),
  because `mix deps.get`/`npm ci` may be needed when the head changed the lockfile (the
  `DepsCache` is keyed on the default branch's `mix.lock`). No ticket grants, no Wardmast
  bridge, no MCP, no `arb`. `:no_public_upload` hosts stay hard-denied.
* **Resource limits.** The pod gets its own cgroup limits, independent of the worker's:
  `limits.memory` (default 4 GiB, max 16), `limits.cpus` (default 2), `--pids-limit 1024`,
  and the wall-clock budget of §4. It takes one capacity slot (like a fix pass), so it
  cannot starve implementers; a locally-run pass is wrapped in the same per-spawn scope
  that bounds agent spawns (`MemoryScope`), so an OOM kills the pass and nothing else
  (`memory_cap_exceeded`, GitHub #265).
* **Preemption and loss.** A pass is **idempotent and keyed**: `(task, head_sha, plan_hash,
  config_hash)`. If a node is lost or a pod is evicted mid-run (`node_lost?` in the executor
  outcome), the capture is retried once, forced to the primary if the primary can run
  podman, then recorded `failed: node_lost` and surfaced as attention. Nothing
  half-finished is ever posted: results are staged and only a **complete manifest** is
  ingested.
* **Image return path.** A node returns `manifest.json` + images as a tar to the primary,
  which extracts it with the same posture as `Wardmast.Nodes.Transcripts` (judged before
  anything is written: no absolute/`..`/NUL paths, regular files only, only `*.png|webp|jpg`
  and `manifest.json` extracted, entry/byte caps). The primary does the hosting
  upload (§7), so **no forge credential ever enters the pod or a node**.

### As implemented: the capture sandbox (bd-bhrsdv)

The capture step that exists today (`Wardmast.Screenshots.Capture`, run by the ReviewGate on the
primary, §4) boots the app with the **host's** toolchain, not in the pod: placement, images and
the pod are N2. Until bd-bhrsdv it also ran with the host's network and filesystem, as the
coordinator's user, so a change's app could reach the coordinator on `127.0.0.1:4848`, any
external host, and the coordinator user's files. Now **everything a capture boots runs in a
sandbox, or not at all**:

* **The seam.** `Wardmast.Screenshots.Capture.Sandbox` (behaviour). `Capture.run/2` checks
  `status/0` right after the `ui_paths` gate, before the plan is read or anything runs; the
  booter and the shooter refuse a spec without one. There is no unsandboxed implementation.
* **Fail closed.** A host that cannot provide it gets `{:skipped, {:no_sandbox, reason}}`,
  `reason` = "capture needs a sandbox: <what is missing>" (recorded in `capture.json` as
  `skip_kind: no_sandbox`). The ReviewGate proceeds and tells the reviewer no screenshots were
  taken and that it is the host's setup, not the worker's change. This replaces the "Podman only
  in v1 ... `skipped: capture needs the podman sandbox`" rule above for host-mode capture.
* **Pod or bwrap: bwrap, for host mode.** The pod is the right home for N2 (repo image,
  sidecar browser, placement), but host-mode capture runs the host's toolchain, which a pod
  would not have, and it needs a guarantee now. `Sandbox.Bwrap` gives it on the host, and its
  isolation runs for real in CI's `jail` job (`capture_sandbox_test.exs`, real bwrap, where
  podman tests are opt-in and never run in CI). A pod sandbox can implement the same behaviour
  when N2 lands.
* **What the bwrap sandbox is.** `--unshare-all` (its own network namespace: `lo` only, no
  route, so the host's loopback is an empty one and every other address is unreachable; its own
  pid namespace; `--die-with-parent`). The filesystem is an **allowlist**: `/usr`, `/bin`,
  `/sbin`, `/lib*` and `/etc` read-only, private `/tmp`, `/run`, `/var/tmp`, `/dev/shm`, the
  extracted checkout and the boot's scratch writable, and nothing else (no home, no host `/tmp`,
  no runtime sockets) unless the operator lists a path in `screenshots.sandbox.readonly_paths`
  (a toolchain, a dependency cache; never the home directory or above). Whatever a listed path
  would show of the server itself is blanked: its secrets and control-socket dirs
  (`Jail.secret_files/0`, `Jail.mask_paths/0`) and its own trees and sockets
  (`Sandbox.Bwrap.own_roots/0`: other workers' worktrees, scratch and egress/bridge sockets, the
  data home and accounts). The masks come before the boot's own binds, so a checkout under a
  masked dir still shows. The env stays built from nothing, now with `HOME` in the scratch.
* **Reaching the app.** The app listens on `127.0.0.1:<port>` in its namespace. The host creates
  a listening Unix socket in a fresh `0700` dir under `Paths.socket_root/0`, **outside** the
  sandbox, and passes it in as fd 3; a relay inside hands each connection to the app's port. The
  app never sees the socket's path, so it cannot swap it for a symlink that would turn the host's
  readiness probe into a request to another host socket. Host-side probes go through `Req`'s
  `unix_socket:` and read only the status, never an untrusted body.
* **The browser.** Chromium runs in a sandbox of its own: only the shot's directory writable,
  the browser's install dir and the app's socket read-only, a `socat` bridge from
  `127.0.0.1:<port>` to that socket (so it loads the same `base_url`), an env built from nothing.
  The image is copied out only if it is a regular file.
* **`--no-sandbox` stays, deliberately.** Chromium's own sandbox does not start inside this one
  on hosts that restrict unprivileged user namespaces (its namespace sandbox needs a nested user
  namespace; Ubuntu's AppArmor policy and container seccomp profiles refuse that, and the podman
  worker container refuses `unshare --user`) and its setuid helper cannot gain privileges under
  bwrap's `no_new_privs`. It would also protect the wrong thing: it shields the browser process
  from a compromised renderer, but that process holds nothing (fresh profile per shot, no
  cookies, no credentials, empty env) and the page's author already runs arbitrary code as the
  app in an equivalent sandbox. What must stay unreachable from the page (host loopback, other
  hosts, host files) is unreachable because of the capture sandbox. The flag is documented at
  `Shooter.Chromium.argv/2` and must never be used outside `Sandbox.browser/3`.
* **Consequences.** No network means `setup_cmd` cannot fetch dependencies or download asset
  tools (`mix deps.get`, `npm ci`, esbuild/tailwind installers) unless they are already in a
  listed read-only cache (`HEX_OFFLINE`, `MIX_HOME`, ... pointed at it through `env`). The
  baseline egress allow-list of the "Exits" bullet above is N2's. A toolchain outside the system
  dirs (asdf, mise) must be listed in `readonly_paths`. `bwrap`, `perl` and `socat` are required
  (`perl`/`socat`/`sh` inside the system dirs); `status/0` probes the sandbox for real (only `lo`,
  no route, a host file beside its scratch hidden, the scratch writable), caching a pass and
  re-probing a failure after a minute.

### When it runs, and what it blocks

1. **Trigger.** After the PR/MR exists (so there is a head SHA, a base SHA and somewhere to
   write) *and* the head's diff from the merge-base matches `ui_paths` (and not
   `ignore_paths`). The commit gate checks the plan beforehand (§5.4).
2. **Re-capture** on a new head only when `diff(last_captured_head..head)` touches
   `ui_paths` or the plan changed, debounced 120 s, at most `max_captures_per_ticket`
   (default 3). A head change that is not UI keeps the existing set, whose caption names
   the SHA it was taken at. A changed merge-base alone does not re-capture ("before" is
   labelled with the base it was taken at).
3. **Gating.** Auto-merge waits for the capture for the **current** head to reach a
   terminal state (`posted | skipped | failed | withheld`) (the original proposal also bounded
   this with a `merge_wait_seconds` limit; it was never built and is removed, see below). **A failed capture never fails a merge**: it raises a soft attention
   (`screenshot_capture_failed`), the PR section says what happened, and the ReviewGate
   brief carries the manifest summary so a reviewer sees "captured / failed / withheld".
   Rejected: making capture a hard merge gate; flaky browsers would block unrelated work.

**Implemented (bd-8qj1sa): capture lifecycle.** Every capture attempt is a row in
`screenshot_captures` (`Wardmast.Screenshots.CaptureRecord`, written by
`Wardmast.Screenshots.Captures`): task, head, base, `plan_hash`, `config_hash` and a state
(`running | captured | skipped | failed | superseded`). The ReviewGate uses it for three rules:

- **Supersession.** While a capture is in flight the gate polls `origin/<branch>` every
  `screenshot_head_poll_ms` (default 30s; the `:screenshot_head_poll_ms` gate option, `nil` = off).
  A remote that strictly advanced past the captured head is fast-forwarded onto, the capture task
  is cancelled and its row marked `superseded`, and the gate re-enters at the door it came in by
  (`:first` or `{:next, review_id}`): CI is awaited on the new head when `review.require_ci_green`
  applies, the review checkout is re-provisioned there, then the new head is captured. Any new
  capture for a different head also supersedes a row a dead gate left `running`. A force-push the
  worktree cannot fast-forward to is not seen by the poll (`push_gate/1` owns it).
- **Re-capture skip.** For a head not yet checked, the set taken at the last captured head is
  reused (and the reviewer's brief says which commit it was taken at) when
  `diff(last_captured_head..head)` misses `ui_paths` and the plan hash is unchanged. A gate that
  has lost its in-memory outcome (a restart) captures again rather than reuse a set it cannot show.
- **Cap.** `limits.max_captures_per_ticket` (default 3) bounds the attempts that booted the app
  (`skipped` rows and manifest failures do not count). At the cap the last set is reused, or, with
  none, the reviewer is told no screenshots were taken for that reason.

`merge_wait_seconds` is removed from the schema (a stored value is still accepted and ignored):
the capture finishes in the ReviewGate, before a reviewer, so there is nothing to wait for at
merge. No debounce was built either: a capture starts when the ReviewGate reaches the step for a
head, and a newer head supersedes it.

**Implemented (bd-84latk, #1328): the ReviewGate step.** Before a reviewer is dispatched (after the CI
wait), `Wardmast.Worker.ReviewGate.ScreenshotGate` runs the capture for a repo with a `screenshots`
config and routes the outcome: captured pairs (or the worker's declared `skip`) go into the reviewer's
brief; a **worker fault** (`manifest_missing`, `manifest_invalid`, `route_error`) goes down the revise
loop with an instruction to add or fix `.arbiter/screenshots.json`; an **infrastructure fault** (every
other failure code: boot, checkout, diff, budget, browser) parks `:screenshot_capture_failed` for the
coordinator and neither loops the worker nor dispatches a reviewer. A repo with no `screenshots`
config is untouched.

Why not wait inside the worker's commit gate (`arb done`, ≈ 3 min, bounded by the
pre-push recipe)? Two cold boots exceed it, and the PR does not exist yet. The *plan check*
(cheap, no boot) does run there.

## 3. Lifecycle and state

A `screenshot_captures` row per attempt: `id, task_id, repo, head_sha, base_sha, plan_hash,
config_hash, state (queued | running | posted | skipped | failed | withheld), skip_reason,
manifest (json), error, started_at, finished_at, pass_node`. Images are ticket attachments
(bd-5hlegn) with `source: "arbiter-capture"` and provenance (`capture_id, head_sha, base_sha,
shot_id, viewport, theme, role, sha256`). **Only Arbiter writes `source: "arbiter-capture"`**,
which doubles as the evidence-integrity guarantee: a worker cannot attach an image to the
table, so what the table shows was captured from the app by the pass
(`Wardmast.Worker.EvidenceIntegrity` exists because that happened once).

## 4. Getting the "before" shot (D2)

Two boots of the same app, one per commit, **sequential, in one pod**.

```
primary:   git archive <base_sha> → base.tar        (no .git, no history, no remote)
           git archive <head_sha> → head.tar
pod:       for role in [before(base), after(head)]:
             extract → /work/<role>          (fresh dir each)
             seed deps (DepsCache, image-keyed) → setup_cmd → seed_cmd → start_cmd
             readiness probe → login → shots → stop app (TERM, KILL after 10 s)
           write /out/manifest.json + images
```

* **Source trees come from `git archive`, not clones.** Same read-only intent as
  `Preview.Checkout` ("never touches a worker's checkout") with less: no `.git`, no `origin`
  to remove, nothing to push with, small enough to ship in an `assign` to a node. Both SHAs
  are resolved on the primary after a fetch (the `PassPlacement.seed/3` refresh logic); the
  **head SHA is the forge's** `remote_head`, not the local clone's. Limit: submodules and
  Git LFS are not in an archive; a repo using them is `skipped: submodules/lfs` in v1.
* **Merge-base, not target tip.** `git merge-base origin/<target> <head>`: the "before" is
  what this branch started from, so the diff of the two pictures is this branch's work and
  not other people's merges.
* **Sequential, not concurrent.** Concurrent boots halve wall-clock but double peak
  memory, double the port and DB bookkeeping, and make two apps compile at once. They
  also share one netns here, so two apps would fight over one port. One boot at a time,
  one port (`port_range` is only used to pick it; inside the pod's private netns it can
  never clash with anything, so **no cross-ticket port lease is needed**: that is
  host-mode `preview_leases` machinery we avoid by isolating).
* **A fresh database per boot, built from scratch.** Never reuse one DB across the two
  commits: the head's migrations are generally not reversible against the base schema and
  the base's code does not understand the head's. Each boot runs `setup_cmd` (which
  includes `ecto.create`/`migrate`, or the repo's equivalent) and then `seed_cmd` against
  its **own** `{{scratch}}` DB (a SQLite file under the pod's tmpfs, or a database in the
  pod's test-services Postgres named `{{role}}`). `{{role}}` is `before` or `after`, so a
  Postgres shared by both never mixes them, and the pod is destroyed afterwards so nothing
  to clean up (compare `app-preview.md`, "Nothing drops it").
* **Both boots use the same `seed_cmd`**, taken from each commit's own tree. If the head
  *changes the seeds* (new fixture), the "before" still boots from its own tree's seeds;
  a shot whose path or selector does not exist at the base renders as **new** (below),
  not as a failure.
* **Missing before.** Per shot: base navigation returns 404, the first selector never
  appears within its timeout, or the base boot itself failed. The row says
  `new at this commit` (404/selector) or `before unavailable: <reason>` (boot failure) and
  shows only the "after". A shot that renamed its route sets `before_path`.
  The reverse (head fails) is a **failed** shot: no image is invented, the row says why.
* **Timing budgets** (all configurable under `limits`; defaults from the podman design's
  measurements: a cold `mix deps.compile` ≈ 200 s, warm ≈ 17 s, `mix compile` ≈ 2 s):

  | Phase | Default | Notes |
  |---|---|---|
  | archive + image ensure + pod start | 60 s | image cold-start measured at ~6 s once per image |
  | `setup_cmd` per boot | 600 s | warm `DepsCache` ≈ 20–90 s; a cold compile is the long case |
  | `seed_cmd` per boot | 120 s | |
  | `ready.timeout_seconds` | 120 s | stopped and marked failed |
  | per-shot (steps + capture) | 30 s | steps have their own ≤ 10 s waits |
  | **whole pass** (`budget_seconds`) | 1200 s, max 3600 | hard kill; partial results discarded unless every shot finished |

  Warm `_build` for the "before" is a later optimisation (seed it from the head's after
  compile); v1 pays two compiles.

* **As implemented (bd-1ydndq).** `Wardmast.Screenshots.Capture.run/2` is the deterministic step
  (no agent turn). It returns `{:skipped, :no_ui_paths}` having run nothing when the diff misses
  `ui_paths`, reads the worker plan (`Screenshots.Plan`), then extracts each commit with
  `git archive`, boots it through a `Capture.Booter` (default `Booter.Command`: setup, seed, start,
  readiness probe, in an empty environment), shoots every `shot x viewport x theme` through a
  `Capture.Shooter` (default `Shooter.Chromium`, the command-line browser) and stops it: base first,
  then head. A 404 means *absent at that commit*: absent at the base is a `:new` pair (after-only),
  absent at the head a `:removed` pair (before-only), absent at both a route error. Failures are
  `Capture.Failure`s with a distinct `code` (`manifest_missing`, `manifest_invalid`, `boot_failed`,
  `route_error`, `shot_failed`, `budget_exceeded`, ...), written to `<out_dir>/capture.json` and
  handed to `opts[:record]`. A boot failure at the base **fails** the capture (it does not degrade
  to `before unavailable`). Differences from the sketch above: it boots on the host, not in the pod
  (the pod, the `screenshot_captures` table, placement and the merge wait are N2), though since
  bd-bhrsdv only ever inside the bwrap capture sandbox (§2, "As implemented: the capture
  sandbox"; no sandbox is `{:skipped, {:no_sandbox, reason}}`), and
  `Shooter.Chromium` cannot run steps, `wait_for`, `target`, `full_page`, `hide`, a login or theme
  `local_storage`: it fails the shot naming the unsupported field. `Capture.poster_pairs/1` hands
  the pairs to `Screenshots.Poster`. (The default shooter is now `Shooter.Auto`; see N1 below.)

* **As implemented: N1 (bd-485ts3), the login-capable capture shooter.** Built as a second
  `Shooter` behind the seam above rather than the whole runner/manifest of §11's N1 row (the
  manifest, boot loop and marker/DOM scans already live in `Screenshots.Capture` and the later
  tickets). What shipped:
  * `Shooter.Cdp` + `priv/capture/runner.mjs` (Node + `playwright-core` 1.65.1 over CDP): one
    runner process and one fresh browser context per image. It does a **form login**, `steps`
    (all eleven actions of §5.2), `wait_for`, `target`, `full_page` (clipped to 8000 px), `hide`
    and the theme's `local_storage`, with timezone UTC, locale `en-US`, the viewport's size and
    scale, reduced motion, animations off, a frozen clock (`2026-01-01T12:00:00Z`) and a
    network-idle + font-ready wait.
  * **Isolation: the same capture sandbox as the command-line shooter, plus a little more.** The
    runner (Node and Chromium) is started through `sandbox.browser/4`, never on the host: a
    namespace of its own with no network but the `socat` bridge from `127.0.0.1:<port>` to the
    booted app's socket (the only way to reach an app that listens inside its own sandbox), the
    capture directory and the Chromium binary's directory read-only, the shot's `scratch` the
    only writable path, and `env -i`. This is also what justifies Chromium's `--no-sandbox`
    (§2). `Cdp.shoot/1` refuses a spec with no sandbox, booted `app` or scratch dir ("no capture
    sandbox"), like `Shooter.Chromium`. The spec file (it can hold a fixture password) is
    created `0600` in `scratch`, deleted by the runner as soon as it has read it, and `scratch` is
    removed after the shot; the image is copied to `out_file` only when it is a regular file, and
    a runner that answers "ok" with no image is a failed shot. Inside the browser, a
    non-loopback `base_url` is refused, no host but loopback resolves and every non-loopback
    request is aborted.
  * `Shooter.Auto` is the capture step's default shooter: the command-line `Shooter.Chromium`
    keeps every shot it can do, `Shooter.Cdp` takes any shot for which
    `Shooter.Chromium.unsupported/1` is non-empty (login, steps, `wait_for`, `target`,
    `full_page`, `hide`, theme `local_storage`); one list, so the two cannot drift.
  * **Login semantics.** `login.success` is now defined and validated
    (`Screenshots.Config`): `{"path_not": "/login"}` (the browser has left that path) and/or
    `{"url_not_contains": "/sign-in"}` (its URL lacks that text), every given condition must hold
    after the form is submitted; any other shape is refused. Unset, it defaults to
    `path_not = login.path`. The shot **fails**, with the persona and where the browser ended
    up, when the condition does not hold within the login timeout (10 s); when the condition
    already holds on the sign-in page itself (it could not tell a failed login from a good one);
    and when the shot's route, or a step, lands back on the sign-in page. A sign-in page is
    never shot as an "after". `login.kind` `cmd` is not supported by this shooter (it fails the
    shot with that reason). Each condition must be false on the sign-in page itself: one
    its own URL already satisfies (say `url_not_contains: "error="` alone) cannot tell a failed
    login from a good one, and the runner refuses the shot rather than trust it; use `path_not`
    (or leave `success` unset) for that.
  * **Packaging: in the worker image, not a sidecar.** The shared base
    (`Image.base_containerfile/1`) gets the runner and `playwright-core` (`npm ci
    --ignore-scripts` from the lockfile, so version and integrity are pinned; no browser
    download: the image's Chromium is used) under `/opt/arbiter/capture`, and Node's binary
    from the official Node image, pinned by digest like every other `FROM`, at
    `/opt/arbiter/capture/bin/node`, off `PATH` so a repo's own Node layer is untouched. The
    image sets `ARB_CAPTURE_DIR`. Release CI's `scripts/worker-image-smoke.sh` now also runs
    `scripts/worker-image-smoke-capture.sh` in the built base: a login-gated loopback page is
    shot through the real runner and a wrong password must fail. This supersedes the sidecar
    sketch in §4 for the shooter: capture already runs where `$ARB_CHROME` is, and a second image
    is a second thing to pin and keep in step. (The "one browser build for before and after"
    argument still holds: both shots come from the same image.)
  * Tests: `Shooter.CdpTest` drives the real runner against a login-gated fixture app
    (`Wardmast.Test.CdpFixtureApp`) for correct and wrong credentials, both success conditions, an
    unmet condition, a session that does not hold, steps, `wait_for`, `target`, `full_page`,
    theme `local_storage`, determinism and the loopback rule; it is skipped where node,
    `playwright-core` or Chromium is missing (`ARB_REQUIRE_CDP=1` makes that a failure).
    `RunnerImageTest` pins the Containerfile (runner and lockfile baked byte for byte, digest
    pin, node off `PATH`).
    `CdpTest` also proves the sandbox seam: a recording sandbox shows the runner argv goes through
    `browser/4` (capture directory and Chromium read-only, `scratch` the only writable path), and a
    spec without sandbox, `app` or scratch starts nothing; `Bwrap.browser_argv/5` is unit-tested for
    the extra read-only mounts. **Not covered:** the real runner is driven there through a
    pass-through host sandbox (the fixture app listens on host loopback), so the real bwrap bridge
    to Chromium's `--no-sandbox` renderer with the node runner is only checked by those argv tests,
    not end to end on a host with bwrap.
  * **Where it runs today.** `Capture.run/2` still runs in the coordinator process on the host
    (the pod is N2), so a host needs Node and the runner's dependency: `npm ci` in
    `apps/wardmast/priv/capture`, or `ARB_CAPTURE_DIR` / `ARB_CAPTURE_NODE` pointing at a
    checkout or an image's copy. Without them the shot fails with a reason naming what is missing.
  * **What remains.** The image build itself (and so the image smoke) is exercised only by
    release CI, not by `mix test`. No `doctor` probe reports a missing runner on the host. No
    `cmd` login. The §5.3 manifest fields, the §9 marker probe and DOM text scan, the pod and
    `--network none` (N2/N4) are not part of this. Before-and-after shots log in once per image
    (one context per shot), which is simple and costs about a second each.

## 5. The worker → Arbiter contract (D3)

### 5.1 Shape

The worker writes `.arbiter/screenshots.json` in its worktree. It **describes what to
shoot, never how to run anything**: no commands, no scripts, no URLs with a host, no
credentials. Everything that is executed (`start_cmd`, `seed_cmd`, `login`) comes from the
operator's `worker.repos.<repo>.screenshots` config or the repo itself.

* **Delivery.** `arb done` ingests the file: the commit gate validates it, stores a copy
  (and its SHA-256, `plan_hash`) on the run, and the capture pass is fed the **stored**
  copy. It is never read from the repo at the head, so a plan is not needed in the tree and
  cannot differ between before and after. Arbiter writes `.arbiter/screenshots.json` into the
  worktree's `.git/info/exclude` (the mechanism `Mcp.AgentConfig` already uses for the files
  it injects) so a stray `git add -A` cannot commit it into a repo that tracks other
  `.arbiter/` files.
* **Rejected delivery:** committing it. It would land in `main`, drift, and need review.
  **Rejected content:** a worker-written Playwright script (arbitrary code against an
  app, unauditable for what it fetches, non-deterministic); deriving routes from the diff
  (impossible for LiveView/SPA apps; the worker knows what it changed).

### 5.2 Schema (`version: 1`)

Unknown keys at any level are **rejected**. Strings are trimmed UTF-8 without control
characters. `selector` is a Playwright selector string (CSS, `text=`, `role=`,
`data-testid` via `[data-testid=…]`), 1–200 chars.

```jsonc
{
  "version": 1,                       // required, must be 1
  "skip": "docs-only change",         // optional string 1..280. If present, "shots" must be absent
  "notes": "Edit modal is new",       // optional string ≤ 500, shown under the table
  "shots": [                          // required unless "skip"; 1..20 items
    {
      "id": "patient-edit-modal",     // required, ^[a-z0-9][a-z0-9-]{0,62}$, unique in the file
      "title": "Edit patient modal",  // optional, ≤ 80 chars; default = id
      "path": "/patients/1",          // required: starts with "/", no scheme/host, ≤ 300 chars, query allowed
      "before_path": "/patient/1",    // optional; same rules; the path to use at the base commit
      "as": "admin",                  // optional persona; must exist in config login.personas; default = login.default_persona
      "viewports": ["desktop","mobile"],  // optional, 1..4 names from config viewports; default = default_viewports
      "themes": ["light","dark"],     // optional, 1..4 names from config themes;    default = default_themes
      "steps": [                      // optional, 0..12 items, run in order, identically at base and head
        {"action": "click",  "selector": "#edit"},
        {"action": "fill",   "selector": "input[name=email]", "value": "not-an-email"},
        {"action": "press",  "key": "Tab"},
        {"action": "wait_for", "selector": ".error", "state": "visible", "timeout_ms": 5000}
      ],
      "wait_for": {"selector": "#modal", "state": "visible", "timeout_ms": 5000},  // optional, before capture
      "target": {"selector": "#modal"},   // optional: element screenshot; default = the viewport
      "full_page": false,                 // optional bool, default false; ignored with "target"; clipped to 8000 px tall
      "hide": ["#clock", ".relative-time"]// optional 0..5 selectors set to visibility:hidden (nondeterministic text)
    }
  ]
}
```

**Steps.** `action` is one of (all other keys are rejected for that action):

| `action` | keys | meaning |
|---|---|---|
| `click` | `selector` | click |
| `hover` | `selector` | hover |
| `fill` | `selector`, `value` (≤ 200 chars) | replace an input's value |
| `select` | `selector`, `value` | choose an option by value or label |
| `check` / `uncheck` | `selector` | set a checkbox/radio |
| `press` | `key`, optional `selector` | one key (`Enter`, `Tab`, `Escape`, `Control+a`…) |
| `scroll_to` | `selector` | scroll into view |
| `goto` | `path` (same rules as `path`) | navigate (e.g. open a tab) |
| `wait_for` | one of `selector` or `text`; `state` `visible` (default) / `hidden`; `timeout_ms` ≤ 10000 (default 5000) | the *only* synchronisation primitive |
| `wait` | `ms` ≤ 2000 | last resort; discouraged |

**Non-default states** (modal open, validation error, empty state, a menu): describe the
interaction that reaches it. *Modal open:* `click #edit`, `wait_for #modal`. *Validation
error:* `fill` an invalid value, `click` submit, `wait_for` the `.error` text. A **named seed**
state ("an empty list", "a patient with 30 visits") is a fixture the *repo* owns: the
operator lists them in config (`seeds`: name → `seed_cmd`), and the shot says `"seed": "empty"`
(an optional string, must be a key of `seeds`). The worker may *pick* a seed, never define one,
so it cannot make Arbiter run a command or load data of the worker's choosing.

**Limits** (hard validation errors, also enforced again by the pass): ≤ 20 shots; ≤ 4 viewports
× ≤ 4 themes per shot; ≤ `limits.max_images` (default 40) total images counting
`shots × viewports × themes × {before, after}` and the "before"s that are `new`;
duplicate `id` refused.

**Determinism** (fixed by the runner, not configurable by the worker): animations disabled,
caret hidden, `prefers-reduced-motion`, timezone UTC, locale `en-US`, frozen `Date.now()` at
`2026-01-01T12:00:00Z` via Playwright's clock, a fixed viewport, `device_scale_factor` from
config, and a network-idle + font-ready wait before every capture. Before and after use
identical settings by construction.

### 5.3 Output (the `manifest.json` the pass returns)

```jsonc
{
  "version": 1,
  "task_id": "bd-…", "repo": "…", "head_sha": "…", "base_sha": "…",
  "plan_hash": "sha256:…", "config_hash": "sha256:…",
  "boots": [
    {"role": "before", "status": "ok|failed", "duration_ms": 0, "log_tail": "≤ 4 KiB"},
    {"role": "after",  "status": "ok|failed", "duration_ms": 0, "log_tail": "…"}
  ],
  "shots": [
    {
      "id": "patient-edit-modal", "viewport": "desktop", "theme": "light",
      "status": "ok|failed|withheld",
      "reason": "step 2 selector not found | matched data-safety rule `email-domain` | …",
      "before": {"status": "ok|new|unavailable", "file": "patient-edit-modal__desktop-light__before.png",
                 "sha256": "…", "bytes": 0, "width": 0, "height": 0},
      "after":  {"status": "ok", "file": "…__after.png", "sha256": "…", "bytes": 0, "width": 0, "height": 0}
    }
  ]
}
```

### 5.4 Enforcement at `arb done` (the commit gate)

When the diff from the merge-base matches the repo's `ui_paths` and `plan_required` is
true (default), the gate **returns a red step to the same session** (as the pre-push recipe
does) unless `.arbiter/screenshots.json` exists and validates. `{"version":1,"skip":"…"}` is
a valid answer, and the skip reason is printed in the PR section (a reviewer can reject a
lazy skip). If the repo sets `default_routes` and `plan_required: false`, an absent plan
falls back to those routes with the caption `default routes (no plan from the worker)`.
This is how "every UI change" is made true without trusting the worker's judgment of what
a UI change is: the **globs** decide, the worker only chooses *what to show*.

A new verb `arb screenshots check [file]` (MCP twin `screenshots_plan_check`, per the
CLI↔MCP parity rule) validates a plan without a boot and prints each error with a JSON path.

## 6. The per-repo config contract (D4)

`worker.repos.<repo>.screenshots`, merged key-by-key over `worker.screenshots` (repo keys
win; `env` and the `viewports`/`themes`/`seeds` maps merge by key, like `preview`).
**Validated on write** (`ConfigSchema` + a `Screenshots.Config.validate/2` beside
`Preview.Config`): unknown keys and bad values are refused. Unset: **off**, no behaviour change.

```jsonc
{
  "worker": { "repos": { "<repo>": { "screenshots": {
    "enabled": true,                         // default true when the block is present
    "ui_paths": ["lib/*_web/**/*.heex", "lib/*_web/live/**", "assets/**"],   // REQUIRED, non-empty globs
    "ignore_paths": ["**/*.md", "test/**"],  // optional; subtracted from ui_paths
    "plan_required": true,                   // default true (§5.4)
    "default_routes": ["/"],                 // optional; used only when plan_required is false

    "start_cmd": "mix phx.server",           // REQUIRED unless `preview.command` is set (inherited)
    "setup_cmd": "mix deps.get && mix ecto.create && mix ecto.migrate",  // inherits `preview.setup`
    "seed_cmd":  "mix run priv/repo/screenshot_seeds.exs",               // runs after setup, every boot
    "seeds": {"empty": "mix run priv/repo/seeds_empty.exs"},             // named, picked by plans
    "port_env": "PORT",                      // default PORT
    "port_range": "32000-32999",             // default; picks the in-pod port (never leased)
    "base_url": "http://127.0.0.1:{{port}}", // default; host must be 127.0.0.1 or localhost
    "env": {"DATABASE_PATH": "{{scratch}}/{{role}}.sqlite3", "PHX_HOST": "127.0.0.1"},

    "ready": {"path": "/", "timeout_seconds": 120, "expect": "below_500"},  // expect: below_500 | 2xx

    "login": {                               // default {"kind": "none"}
      "kind": "form",                        // none | form | cmd
      "default_persona": "admin",
      "path": "/login", "username_selector": "#email", "password_selector": "#password",
      "submit_selector": "button[type=submit]", "success": {"path_not": "/login"},  // and/or {"url_not_contains": "/sign-in"}; default: path_not = path
      "personas": {"admin": {"username": "admin@example.com", "password": "fixture-only-password"}}
      // kind "cmd": {"cmd": "mix run priv/repo/screenshot_login.exs {{persona}}", "personas": ["admin","viewer"], "default_persona": "admin"}
      //   stdout = Playwright storageState JSON (≤ 64 KiB), run after seeding, in the boot's env
    },

    "viewports": {                           // default shown
      "desktop": {"width": 1280, "height": 800, "device_scale_factor": 1},
      "mobile":  {"width": 390,  "height": 844, "device_scale_factor": 2}
    },
    "default_viewports": ["desktop"],
    "themes": {                              // default shown
      "light": {"color_scheme": "light"},
      "dark":  {"color_scheme": "dark", "local_storage": {"theme": "dark"}, "query": {}}
    },
    "default_themes": ["light"],

    "fixture_check": {"marker": {"path": "/health", "contains": "\"data\":\"fixture\""}},  // §9
    "deny_patterns": ["acme-corp\\.com"],    // extra regexes for the DOM text scan
    "fixture_email_domains": ["example.com", "example.org", "example.net", "test", "invalid", "localhost"],

    "limits": {
      "max_shots": 20, "max_images": 40, "max_image_bytes": 2097152, "max_capture_bytes": 25165824,
      "setup_seconds": 600, "seed_seconds": 120, "shot_seconds": 30, "budget_seconds": 1200,
      "memory": "4g", "cpus": 2, "max_captures_per_ticket": 3
    },
    "hosting": {
      "github": {"mode": "assets_branch", "branch": "arbiter-assets"},
      "public_repo_ok": false,               // §7.4
      "retention_days": 90
    },
    "attach": true,                          // also store on the ticket (§10); false = PR/MR only
    "sandbox": {                             // bd-bhrsdv: host-mode capture sandbox (§2)
      "readonly_paths": ["~/.asdf", "~/.mix"] // shown read-only; never ~ or above; default []
    }
  }}}}
}
```

* **Templates** (`start_cmd`, `setup_cmd`, `seed_cmd`, `seeds` values, `env` values,
  `base_url`, `login.cmd`): `{{port}}`, `{{role}}` (`before`/`after`), `{{scratch}}`
  (per-boot scratch dir), `{{checkout}}`, `{{task_id}}`; `{{persona}}` in `login.cmd` only.
  Anything else is refused (the `Preview.Config` rule).
* **Validation beyond types:** `ui_paths` globs use the visual-baselines dialect (`*`, `**`,
  `?`); `base_url`'s host must be loopback; `env` values may not contain a URL (or
  `host:port`) with a non-loopback host, and **may not set** `HTTP_PROXY`, `HTTPS_PROXY`,
  `ALL_PROXY`, `NO_PROXY` or any key already scrubbed by `SpawnEnv` (the pass sets its
  own); `viewports` names `^[a-z0-9-]{1,20}$`, 200–3840 × 200–4000 px, scale 1–3; `limits`
  have a floor and a ceiling (`budget_seconds` ≤ 3600, `memory` ≤ `16g`); `login.form`
  passwords are **fixture credentials** (never real accounts), and config reads should redact
  them like other secret-shaped values.
* **Inheritance from `preview`.** The two blocks describe the same thing (run this app on a
  throwaway database), so when `screenshots.start_cmd`/`setup_cmd`/`ready` are unset they
  fall back to `preview.command`/`preview.setup`/`ready_path`+`ready_timeout`. `preview`'s
  `env` is **not** inherited: preview `env` often points at host paths
  (`DATABASE_PATH=/tmp/preview-…`) and the data-safety rule wants every pointer into the
  pod's scratch, stated explicitly.
* **Example for this repo (Phoenix + SQLite):**

```json
{"worker":{"repos":{"arbiter":{"screenshots":{
  "ui_paths": ["apps/wardmast_web/lib/**/*.heex", "apps/wardmast_web/lib/**/live/**", "apps/wardmast_web/assets/**"],
  "setup_cmd": "mix deps.get && MIX_ENV=dev mix ecto.setup",
  "seed_cmd": "mix run apps/wardmast/priv/repo/screenshot_seeds.exs",
  "start_cmd": "mix phx.server",
  "env": {"DATABASE_PATH": "{{scratch}}/{{role}}.sqlite3",
          "SECRET_KEY_BASE": "screenshot-only-not-a-secret-screenshot-only-not-a-secret-0000",
          "WARDMAST_CLOAK_KEY": "…throwaway base64 key…"},
  "ready": {"path": "/", "timeout_seconds": 180}
}}}}}
```

## 7. Image hosting (D5)

### 7.1 GitLab: uploads API

`POST /projects/:id/uploads` (multipart `file`) returns `{alt, url, full_path, markdown}`;
the `markdown` (a project-relative `/uploads/<secret>/<name>`) renders inline in an MR
description. It is project-level, so it works **before** the MR exists and survives the MR.
The GitLab merger adapter (it already speaks Req with the instance's scheme/base URL and
custom CA, `Mergers.Gitlab`) gains `upload_image/3`. Access: for a private/internal project
only authenticated project readers see the image; for a public project anyone with the
URL. Retention: tied to the project; Arbiter does **not** garbage-collect GitLab uploads
(not verified whether the operator's GitLab version exposes a delete endpoint; the doc
promises none). Size limit: the instance's max attachment size, far above ours.
Rejected: also pushing an assets branch to GitLab; the uploads API is the operator's chosen
route and needs no ref.

### 7.2 GitHub: no image-upload API. Options

| Option | Renders in the PR body for readers of a **private** repo | Public repo | Retention / cleanup | Side effects | Verdict |
|---|---|---|---|---|---|
| **Orphan assets branch**, SHA-pinned `blob/<sha>/…?raw=true` | Yes for readers who can see the repo: the URL is on `github.com`, served with the viewer's session (a 302 to a short-lived signed `raw.githubusercontent.com` URL). **To be confirmed by a spike on a real private repo, §12 R1** | Readable by anyone with the URL, permanently (history) | Fully in Arbiter's hands: prune files, or (rarely) squash history | An extra branch; plain git push; reuses VisualBaselines' throwaway-checkout push and `HostCredential`. An orphan branch has no `.github/workflows`, so no push workflow runs | **Chosen** |
| Release assets | Download URLs of private-repo assets are auth-redirected and (draft releases) visible only to writers; not a documented `<img>` embed. Unproven | Public, permanent | Delete the release | Tags and releases, `release` events and workflows, watcher notifications, release-list noise | Rejected |
| Hidden ref (`refs/arbiter/screenshots`, not a branch) | Not established: GitHub's web UI resolving a SHA reachable only from a custom ref is unverified | as above | as above | Smaller footprint (not cloned by default); no branch list noise | Rejected for v1; revisit only if clone size of `arbiter-assets` becomes a complaint. Switchable later behind `hosting.github.mode` |
| **Arbiter-hosted URL** | **No**: the dashboard is loopback-only (`docs/remote-access.md`). Exposing it would put the coordinator on the internet, and Arbiter cannot honour the repo's ACL for a reader | n/a | dies with the host | New attack surface | Rejected |
| Commit images into the PR branch (`docs/pr-assets/<n>/`, the manual precedent) | Yes | Yes | Forever in `main`'s history once merged | Pushes a new head: re-runs CI, **invalidates the reviewed SHA** (a fresh review round), and is circular (the capture is of the head the push just replaced) | Rejected |
| GitHub's drag-and-drop uploader (`user-attachments`) | n/a | n/a | n/a | Undocumented, cookie-authenticated browser endpoint; no API | Rejected |
| `data:` URIs in the body | No: stripped by the renderer; 65,536-char body cap | n/a | n/a | n/a | Rejected |
| Public paste/file hosts, gists | Forbidden (`:no_public_upload`, `EvidenceIntegrity`) | | | | Rejected by policy |

### 7.3 The assets-branch mechanics

* **Branch.** `arbiter-assets` (config), created lazily as an **orphan** with one README
  ("machine-generated screenshots, do not edit or merge") and no other tree content.
  Never merged, no PR from it. Branch-protection note for operators: exempt it from
  rulesets that require PRs on every branch; if the push is refused Arbiter degrades to
  the ticket attachment + PR *comment text* (no images) and raises
  `screenshot_hosting_blocked` rather than failing the capture.
* **Layout.** `t/<task_id>/<head_sha12>/<shot-id>__<viewport>-<theme>__<before|after>.<ext>`.
* **Write path.** A throwaway clone on the primary (never a shared checkout),
  `git checkout` of the assets tip, add the capture set, **one commit per capture set**
  (`Add screenshots for <task_id> @ <head12> [skip ci]`), plain non-forced push with the
  repo's `HostCredential`; a rejected (non-fast-forward) push re-fetches and re-applies,
  up to 3 times; writes are serialised per repo in the coordinator (one process, so a mutex
  suffices). The GitHub App token has no `.github/workflows/` access, which this never needs.
* **As implemented (bd-3tox5h).** `Mergers.Github.AssetsBranch` writes the commit through the
  Git Data API (blob, tree, commit, ref update; one non-forced ref move, up to 3 attempts on a
  rejected update) rather than a throwaway clone and `git push`: same one-commit-per-set
  result, same credential, no checkout on the primary, and it is covered by stubbed-API tests.
  `Screenshots.Poster` hosts, renders (`Screenshots.Section`, `## Screenshots`, replaced in
  place between marker comments) and writes the description; `SyncPrBody` carries the block
  across a worker's `pr_body` edit. The `screenshot_captures` state machine, the
  `hosting.*` config and the `screenshot_*` attention causes of N2 are not part of it: failures
  are recorded through the existing `:tracker_sync_failed` cause. R1 (private-repo rendering)
  is still unverified.
* **URL.** `https://<web-host>/<owner>/<repo>/blob/<assets-commit-sha>/<path>?raw=true`
  (`<web-host>` from the merger's configured base URL, so GitHub Enterprise Server works).
  Pinned to the **commit SHA**, not the branch, so a later prune or branch tip move cannot
  change what an old PR shows; `?raw=true` makes it an image rather than the blob page.
* **Private-repo implications.** Readers must have read access to the repo to see the
  images, the same as the PR text itself. Not visible in: notification emails (the mail
  client cannot authenticate), link unfurls, the public API without a token, forks of a
  private repo's PR for non-members. Anyone with read access can browse `arbiter-assets`,
  including other tickets' captures: fixture-only data (§9) keeps that harmless, and it is
  the same population that can read the code.
* **Retention.** Pruning = a new commit deleting `t/<task_id>/` of tickets closed longer than
  `hosting.retention_days` (default 90). **History keeps the blobs**, so every SHA-pinned URL in
  an old PR keeps rendering while the branch exists; the cost is repo size. Reclaiming that
  needs a history squash (`arb screenshots gc --squash`, an explicit operator command that
  force-recreates the branch), which **breaks old PR images** (the GitHub-side objects may be
  unreachable and are eventually collected); the PR sections fall back to text, and the
  ticket attachments (while retained) still hold the images. The size ceilings (§10) exist
  to keep that history small: ≤ 24 MiB/capture × ≤ 3 captures/ticket.

### 7.4 Public repos

Public images are world-readable and **irrevocable in practice** (cached, indexed, in
history even after a prune). Same machinery on both forges, with a switch:

* Visibility is read from the forge (`GET /repos/:o/:r` `private`/`visibility`;
  GitLab project `visibility`) at post time, cached 10 minutes.
* **`public`, or unknown/unreadable: fail closed.** Without `hosting.public_repo_ok: true`
  the PR section is *not* posted with images; the ticket attachment still is, and the PR gets
  a one-line text notice and a `screenshot_public_repo_blocked` attention. The operator sets
  `public_repo_ok` once per repo, deliberately (the code is already public, and captures
  are fixture-only).
* GitLab `internal` (any logged-in user of the instance) is treated like private.

Alternatives considered for public repos: always allow (the opt-in costs one line, the
unrecoverable-exposure downside does not); never allow (needlessly forbids the case the
requirement most cares about showing off).

## 8. Composing the PR description

Screenshots are a **section Arbiter owns**, delimited by markers, stored in
`screenshot_captures.rendered_section`, and **never stored in `issue.pr_body`**.

```markdown
<!-- arbiter:screenshots:start head=abc1234 base=def5678 plan=9f3c… -->
## UI changes: before / after
_Captured by Arbiter from fixture data at `abc1234` (before: merge-base `def5678`)._

| Page | Before | After |
|---|---|---|
| **Edit patient modal** · desktop · light | <img src="…" width="380" alt="before"> | <img src="…" width="380" alt="after"> |
| **Settings** · mobile · dark | _new at this commit_ | <img src="…" width="380" alt="after"> |
| **Billing** · desktop · light | _capture failed: step 2 selector not found_ | |

<details><summary>3 more (desktop · dark)</summary>…</details>
<!-- arbiter:screenshots:end -->
```

* **One composer** (`PrBody.compose(pr_body, section)`): strips any marker block the worker
  echoed into `pr_body`, then appends the section. **Both** `SyncPrBody` and the PR-open path
  call it, so a worker's later `pr_body` update does not erase the images (finding 1).
  The section is written by `Mergers.update_description/3` after a capture, using the
  same composer.
* **Order of operations on first capture:** upload/push images → render section with the
  final URLs → `update_description(compose(pr_body, section))`. GitLab uploads and the
  GitHub assets push need no PR, so a capture that finishes before the PR opens (not the
  normal order) is included in the opening body.
* **Size guard.** The section is ≤ 12,000 characters (GitHub's body cap is 65,536 and the
  worker's own text needs room): the first 8 rows render, the rest fold into the
  `<details>`, and anything over the cap is dropped from the PR (still on the ticket) with
  a count.
* `<img width>` keeps tables readable on both forges; both render it in descriptions.
* A `skip` reason, a failed capture, a withheld shot and a public-repo block are all rendered
  as text rows. **A UI change never ends with silence.**

## 9. Data safety (D6)

The rule: **captures only ever use seed/fixture data**. A documented rule fails the first
time a repo's `.env` is lying around, so this is enforced in layers, from the strongest.

1. **Structural isolation (the guarantee).** The pass runs in a pod with `--network none`
   and, as exits, only the egress proxy's *baseline* allow-list. There is **no route to a
   production database, an internal API or the host's loopback** (the `TestServices` design
   proves host loopback absence in `podman_test.exs`). The app reads a database that the pod itself
   creates from `setup_cmd`+`seed_cmd` on a pod-private tmpfs or the pod's own Postgres.
   Real data is not *prohibited* from being loaded; it is *unreachable*.
   **As implemented today (bd-bhrsdv)** host-mode capture gets this layer from the bwrap capture
   sandbox (§2): no network at all (not even the baseline allow-list), no host loopback, no host
   files beyond the system dirs and listed read-only paths, and no capture at all on a host
   that cannot sandbox it. `capture_sandbox_test.exs` proves it against a real bwrap: a probe
   app and a stand-in browser try a listener on host loopback (which an unsandboxed control
   reaches), an external address and name, and a host file, and all fail.
2. **No inherited environment.** The pass env is built from nothing (`SpawnEnv` scrubbing, then
   only `env`, `port_env` and the pass's own variables). The server's `DATABASE_PATH`, the
   operator's `.env`, cloud credentials, forge tokens and `HTTP(S)_PROXY` are absent.
   The worktree's `.env*` files are not in a `git archive` unless tracked.
3. **Config validation (§6).** `env` cannot carry a non-loopback URL or a proxy variable;
   `base_url` must be loopback; every path variable is a `{{scratch}}` template or relative.
4. **Fixture marker probe (defense in depth, opt-in).** With `fixture_check.marker`, the
   runner `GET`s the marker path after every boot and before every shot and **aborts the
   boot** unless the body contains the string. The app opts in (a `/health` that reports
   `data: fixture` when started with a fixture env flag). Recommended for any repo with a
   production-shaped DB. Without it the repo is relying on 1–3 alone, and the dashboard
   config view says so.
5. **DOM text scan with withholding (the backstop).** Every shot also records the page's
   visible text (`innerText`) and `<img alt>`/`title` attributes, which are scanned
   **before the image leaves the pod** with:
   * secret shapes: private-key headers, AWS/GCP/GitHub/Slack/Stripe-style keys, JWTs, long
     hex/base64 runs, `Authorization:` values;
   * email addresses whose domain is not in `fixture_email_domains`;
   * the repo's own `deny_patterns` (regexes: customer names, real hostnames).

   A hit **withholds** that shot's images (status `withheld`, `reason` = the rule name, never
   the matched text), keeps the rest, and the PR row says `withheld by the data-safety scan:
   email-domain`. The matched text never appears in a log, the manifest or the PR. This does
   not catch pixels (a chart of real numbers); it catches the common leaks (names, emails,
   tokens) and is explicit that it is a backstop.
6. **Host-only egress of images.** Only the primary uploads, only after extraction (§2) has
   validated the tar, only `png|webp|jpg` with a matching magic number and sane dimensions,
   and the PNG/JPEG are re-encoded so metadata is dropped. The pod and the node never hold a
   forge credential, so a compromised app or runner cannot publish anything itself.
7. **Worker-facing text.** The worker prompt states "capture is done by Arbiter from fixture
   data; do not attach your own screenshots to the PR, and do not point the app at real
   data". This is the **last** layer; it is documented, and 1–6 are what *enforce*.
8. **Public repos** add the opt-in of §7.4.

What is explicitly **not** promised: pixel-level redaction, and safety for an app whose
fixtures *are* real data (an operator who seeds production extracts into `seed_cmd`). That
is a seeds-review problem, and `seed_cmd` comes from the repo or config, never from the worker.

## 10. Size and retention limits (D7)

| Limit | Default | Notes |
|---|---|---|
| Image types | `png` (default), `webp`, `jpg` | capture emits PNG; over-limit images are re-encoded to lossy WebP (q85), then downscaled `2x → 1x`; still over: the shot is `failed: image too large` |
| Per image | ≤ 2 MiB, ≤ 3840 px wide, ≤ 8000 px tall | full-page clipped |
| Per capture | ≤ 40 images, ≤ 24 MiB | `limits.max_images`, `max_capture_bytes` |
| Captures kept per ticket | latest 2 head sets | older sets are pruned from storage; forge-hosted copies follow §7 |
| Per ticket, all attachments | ≤ 100 MiB, ≤ 200 files | the general ticket-attachment cap (bd-5hlegn); a capture is rejected whole, never truncated |
| Global | 5 GiB (`attachments.max_total_bytes`) | at the limit, closed tickets' blobs are pruned oldest first; open tickets are never pruned |
| Retention | open: kept. Closed: **90 days after `closed_at`** | then the **blob** is deleted, the DB row stays (`pruned_at`) with its provenance and hash, so a ticket still says "had 6 screenshots, pruned" |

* **Storage.** Blobs on disk, content-addressed (`<attachments_root>/<workspace>/<sha256[0:2]>/<sha256>.<ext>`),
  metadata in the DB. Rejected: blobs in the SQLite database (bloats the database file and
  its backups; no streaming reads).
* **Serving.** The dashboard route is authenticated like the rest of the dashboard. It serves
  only an allowlist of raster types (png, jpeg, webp), re-sniffed by magic number at serve time
  and required to match the stored type; anything else is `415`, never inline (no SVG, no HTML).
  Every response sets `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src
  'none'; img-src 'self'; sandbox` and an explicit `Content-Disposition` (`inline` only for a
  verified raster). MCP/API return metadata and a URL, not bytes.
* **Implemented (bd-5hlegn).** `Wardmast.Attachments` (`ticket_attachments` table, blobs under
  `<data home>/attachments`, overridable with `config :wardmast, :attachments, root: …` and the
  limits above by key). Hand attaches (`ticket_attach` MCP, `POST /api/issues/:task_id/attachments`)
  carry `source` `worker`/`coordinator`/`operator` derived from the caller's tier; `arbiter-capture`
  is written only by `Attachments.create_capture/2`. Not yet enforced here, because they belong to
  the capture pass that rejects a capture whole: the per-capture caps (40 images, 24 MiB) and the
  "latest 2 head sets" rule. The 2 MiB re-encode/downscale ladder is likewise the capture pass's;
  the store simply refuses an over-limit image.
* **Deleting a ticket.** The app never destroys a ticket (its paper-trail history references it, so
  `Ash.destroy` fails); a ticket leaves by closing, and the **retention rule above** applies:
  blobs go 90 days after `closed_at`, rows stay with `pruned_at`. A ticket removed out of band
  (a manual SQL delete) has its attachment rows deleted and its blobs removed unless another
  row still references them (`Attachments.sweep_orphans/0`, run hourly by
  `Wardmast.Attachments.Retention` beside the age prune). A reopened ticket is no longer prunable.
* **Upstream mirror seam.** `Wardmast.Trackers.upload_attachment/2` dispatches to an optional
  `upload_attachment/2` tracker callback; no adapter implements it, so
  `Attachments.mirror/2` is `{:error, :not_supported}` today and nothing calls it on attach.
  Per-tracker implementations (Jira, Linear, Shortcut files; GitHub has no public file API) are
  follow-ups.
* **Forge copies are separate.** GitLab uploads are not pruned by Arbiter; GitHub assets are
  pruned per §7.3. Prune ≠ delete from the forge's history.

## 11. Changes to the sibling tickets

> **Status (2026-11-19).** Shipped: config (`bbwppc`), plan contract (N3, in part), hosting and
> composition (`3tox5h`: GitHub assets branch, GitLab uploads, `public_repo_ok` fail-closed),
> ticket attachments (`5hlegn`), the ReviewGate capture step, and the operator doc (N5,
> `docs/screenshots.md`). **Superseded/deferred:** N2 (pod capture pass), the `arbiter-capture`
> sidecar retarget of `6301r0`, N1's Node runner (the host shooter drives Chromium directly).
> **Not shipped:** N4 (DOM text scan/withholding, marker probe) and the `screenshot_*`
> attention causes other than `screenshot_capture_failed`. The table below is the original plan.

The design changes scope in these four, and needs five new tickets. Order:
`bbwppc` and `6301r0` first (parallel) → N1 → N2 → `3tox5h` and `5hlegn` integrate → N3, N4 land
anywhere before N2 is enabled.

| Ticket | Change |
|---|---|
| **bd-bbwppc** Config: `worker.repos.<repo>.screenshots` | Implement the §6 schema exactly, including `login`, `seeds`, `fixture_check`, `deny_patterns`, `limits` and `hosting`, with the §6 validation rules (loopback `base_url`, no proxy/foreign-URL `env`, ranges, template whitelist) and inheritance from `preview`. Add the workspace default `worker.screenshots`. Register in `ConfigSchema` and expose via `workspace_config_get/schema`. Add `Screenshots.Config.resolve/2`. |
| **bd-6301r0** Worker images ship headless Chromium | **Retarget.** Do *not* put Chromium in every repo worker image. Build, pin and publish one `arbiter-capture` sidecar image (Chromium + `playwright-core` + the `arb-capture` runner of N1) through the existing image publisher, with a fixed font set. Remove "per-repo Containerfile" wording. Host-mode Chromium stays out of scope. |
| **bd-3tox5h** Post before/after screenshot table to the MR/PR | Becomes the hosting + composition ticket: (a) merger callbacks `host_images/3` (GitLab uploads API; GitHub assets-branch push + commit-pinned URLs, §7), visibility lookup and `public_repo_ok`; (b) `PrBody.compose/2` used by both `SyncPrBody` and the PR-open path, rendering §8, with the size guard; (c) degraded rows (skip, failed, withheld, blocked). **First acceptance item: a spike proving a `blob/<sha>/…?raw=true` image renders in the description of a PR in a real *private* GitHub repo for a member**, evidence a real screenshot of that PR, run by an operator because no worker holds a credential for it (R1). |
| **bd-5hlegn** Ticket attachments | Add the §3/§10 fields: `source` (`arbiter-capture` only writable by Arbiter), provenance columns, image-only content types with magic-number checks, caps (per image/ticket/global), content-addressed disk store, prune-after-close job leaving `pruned_at` rows, authenticated serve route with `nosniff` and CSP `sandbox`, API + MCP read twins. It is **in addition** to the PR/MR section and must not be the only place images appear. |
| **New N1: `arb-capture` runner + manifest** (login-capable shooter shipped as bd-485ts3, see §4 "As implemented: N1") | The Node/Playwright runner: reads `spec.json`, runs the §4 boot loop for two roles, §5.2 steps, §5.3 manifest, §9 marker probe and DOM text scan, determinism settings. Testable with no cluster. |
| **New N2: capture pass orchestration** | `:capture_pass` in `Nodes.Placement.eligible/1`/`PassPlacement`; `git archive` seeding; pod assembly (worker image + sidecar + test services, `--network none`, baseline egress only); `screenshot_captures` table and state machine; triggers, debounce, supersession and the merge wait (§2); retry on `node_lost`; tar return path with the Transcripts-style sanitiser; attention causes (`screenshot_capture_failed`, `screenshot_hosting_blocked`, `screenshot_public_repo_blocked`). Sets `verify_after_deploy` (first real run is in the live server). |
| **New N3: plan contract** | `.arbiter/screenshots.json` validator (§5.2), `arb screenshots check` + MCP twin `screenshots_plan_check` (parity rule), the `arb done` gate step (§5.4), `.git/info/exclude`, the worker-prompt block. |
| **New N4: data-safety scan** | The §9 text scanner (rules, `fixture_email_domains`, `deny_patterns`), the withholding logic and its tests (including a "matched text never logged" test), plus the config-view note for unmarked repos. |
| **New N5: operator docs** | `docs/screenshots.md`: setup per forge, the `arbiter-assets` branch-protection note, the public-repo opt-in. |

## 12. Risks and what is not verified here

* **R1 (the one that decides GitHub-private).** That a SHA-pinned `github.com/…/blob/<sha>/…?raw=true`
  URL renders in a *private* repo's PR description for a member is the widely used pattern, but this
  worktree has no GitHub credential and no private repo to prove it on, so **it is not verified
  by this design**. It is the first acceptance item of bd-3tox5h. If it fails, no *documented*
  GitHub mechanism renders private-repo images inline in a PR body (releases are unproven, the
  uploader has no API), and the operator requirement cannot be met for private GitHub repos
  without a decision from the operator; do not paper over it with a hosted URL readers cannot open.
* **R2. Clone size.** Every capture adds blobs to `arbiter-assets` permanently. Bounded by §10;
  reclaimed only by an explicit squash that breaks old images. The hidden-ref mode is the
  planned escape hatch.
* **R3. Cold-compile time.** A head that changes `mix.lock` misses the deps cache and compiles
  cold (≈ 200 s per boot measured in the podman design), twice. The default 1200 s budget fits
  the warm case with margin and the cold case tightly; operators with big apps raise
  `budget_seconds`.
* **R4. Apps that need external services** (OAuth, payment sandboxes) render their error
  state: there is no network by design. The login hook (`cmd`) and seeds exist so the app
  does not need them; an operator who adds egress hosts owns that decision.
* **R5. Flaky pixels.** Fixed clock/fonts/animation settings remove the common noise; there
  is no diffing in v1 (the pictures are for humans), so noise is cosmetic, not a gate.
* **R6. `git archive` omits submodules/LFS.** Such repos are `skipped` in v1.
* **R7. The host-mode sandbox is strict (bd-bhrsdv).** With no network, a `setup_cmd` that
  fetches dependencies or downloads asset tools fails the boot, and a toolchain installed under
  the home directory is invisible until listed in `sandbox.readonly_paths`. Both are boot
  failures (escalated, never unsandboxed), so the cost is a configuration round, not a leak.
  Real Chromium inside the bwrap browser sandbox has not been run in the worktree that built it
  (it had no bwrap); the CI `jail` job runs the isolation test with a stand-in browser, and the
  first real capture after deploy is the check for the real one.
* **Not measured.** No boot, no capture and no GitHub/GitLab call was run to write this; the
  timing figures are the podman design's measurements, and the GitLab uploads and GitHub raw-URL
  behaviour is documented API/known behaviour, not observed here.

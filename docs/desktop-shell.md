# Desktop shell prototype

Status: prototype (bd-aisgkf, PKG 8 of the desktop-product epic). The code is in
[`desktop/`](../desktop). This page records the lifecycle decisions it encodes
and what a production shell still has to do.

## What it is

A native wrapper that starts the bundled release, keeps it alive, shows the
dashboard in a window, lives in the tray/menu bar, and stops the release when
the user quits.

```
desktop/
  shell-core/   lifecycle logic, std + libc + serde_json only (no GUI deps)
    supervisor  start / watch / backoff / boot-failure / stop
    port        free loopback port selection
    shell       what "close window" and "Quit" mean
    quit        live-work check against GET /api/scheduler/status
    single_instance  flock + unix socket
    status_page the HTML shown while there is no dashboard (boot failure!)
    bin/fake_release   stand-in server for tests
    bin/headless       windowless shell driven over stdin/stdout (smoke test)
  src-tauri/    UNBUILT sketch of the Tauri window + tray over shell-core
```

**Shell technology.** The PKG 1 decision record (bd-5n0b4w) was not readable
from this task's scope, so the choice was inferred, not read: the follow-on
"Linux desktop build via the same shell" (PKG 22) only makes sense for a
cross-platform shell, so this is **Tauri (Rust)**. If PKG 1 chose Swift, the
Rust `shell-core` is still the spec: every rule below is covered by a test that
can be ported 1:1. Confirm against PKG 1 before building on it.

## How it was verified

`cd desktop && cargo test` (40 tests, ~2 s; needs only a Rust toolchain, no
webview). Verified on Linux; the Unix-only pieces (`flock`, unix sockets,
`SIGTERM`) are shared with macOS but macOS was not run.

* Unit and integration tests run the supervisor against `fake_release`, a small
  binary that binds `$WARDMAST_PORT` and answers `/api/version` and
  `/api/scheduler/status`, with env switches for crash / hang / boot failure /
  ignore-SIGTERM / N workers in flight.
* `tests/headless.rs` is the scripted smoke test: it runs the real `headless`
  binary as separate OS processes (two launches, close, quit, boot failure).
* **Not exercised:** a real `mix release` bundle, and the Tauri layer. See
  [What is left](#what-is-left-for-a-production-shell).

## Lifecycle decisions

### Supervising the release

* The shell launches `<release>/bin/wardmast start` (foreground, so the pid it
  holds is the server's) and passes the port in `WARDMAST_PORT`. That variable
  wins over `PORT` in `Wardmast.Env.server_port/0` and is what `arb` reads
  (PKG 10), so shell and CLI agree.
* **Ready** means `GET /api/version` answers 200 (anonymous on loopback, see
  `WardmastWeb.Plugs.ApiAuth`). Polled every 250 ms, 60 s timeout.
* **Crash after being ready:** restart forever with exponential backoff
  (1 s, 2 s, 4 s … capped at 30 s); the curve resets after 60 s of stable
  uptime so a once-a-day crash does not creep toward the cap.
* **Never gets ready** (exit during boot, or alive but silent past the
  timeout): after 3 consecutive attempts the supervisor stops and surfaces
  `BootFailed` with the reason and the last 200 lines of release output. The
  window shows that (`status_page`, output HTML-escaped) with a *Try again*
  button; looping forever behind a spinner would hide a broken install.
  Quit still works from this state.
* Release output is captured into a ring buffer, not written to disk.
* The release runs in its own process group so a Ctrl-C aimed at the shell does
  not hit it, and a final SIGKILL can take the group.

### Port selection

* Every launch tries the preferred port first (default 4848; the previous
  launch's port after the first run, so a bookmarked tab keeps working), and
  otherwise takes an OS-assigned free loopback port.
* The chosen port goes to the release via `WARDMAST_PORT`, and the window opens
  `http://127.0.0.1:<port>/` from the supervisor's `Running { port }` state, so
  the URL can never disagree with what the release was told.
* Known gap: check-then-use. If something takes the port between the probe and
  the release binding it, the release dies at boot, which counts as a boot
  failure and the next attempt re-probes.
* Only IPv4 loopback is probed, which matches the server: `config/runtime.exs`
  binds 127.0.0.1 unless `WARDMAST_BIND_ADDRESS` says otherwise. The shell must
  not inherit a user-set `WARDMAST_BIND_ADDRESS` (it would probe the wrong
  address); the prototype does not scrub it.

### Close window vs Quit

| Action | Effect |
| --- | --- |
| Close window | Hide to tray/menu bar. The release keeps running, so workers continue and `arb`/MCP keep working. |
| Tray → Open | Show and focus the window. |
| Quit, nothing in flight | Stop the release, exit. No prompt. |
| Quit, workers live | Ask ("Quit" / "Keep running"). Declining changes nothing. |
| Quit, drain state unreadable | Ask too. Unknown is never treated as idle. |

* "Live" comes from `GET /api/scheduler/status` (`Wardmast.Board.Drain`, the
  same body as `arb scheduler status`): a non-empty `in_flight` list. That
  route needs a bearer token; **the prototype has none by default** (PKG 9 owns
  shell-managed credentials), so today a real release answers 401 and Quit
  always asks. The shell takes the token as a constructor argument for when it
  exists.
* "Stops the release" is **SIGTERM**, then SIGKILL after 45 s. SIGTERM runs the
  server's orderly shutdown: each worker traps exits and stamps its run
  `interrupted` / "server shutdown" within `Wardmast.Worker.shutdown_grace_ms/0`
  (15 s), which is exactly what `Wardmast.Workers.Reconciler` and the resume
  sweeps need to pick the runs up on the next start. The 45 s grace is
  deliberately well above that. A kill that lands mid-shutdown is still
  recoverable (the reconciler is the backstop, see its moduledoc), just noisier.
* Quit does **not** pause the autopilot first. Between the check and SIGTERM a
  tick may dispatch one more worker; it is interrupted like any other and
  resumed next start.
* Quit does not wait for work to finish. "Wait for drain" is a possible later
  choice in the dialog.

### Single instance

* The first launch takes an exclusive `flock` on `<socket>.lock` and binds a
  unix socket; later launches fail the lock, send `focus` to the socket, wait
  for the acknowledgement and exit **without touching the release**.
* The lock is dropped by the kernel when the holder dies, so a crash never
  wedges the next launch; a stale socket file is replaced by whoever wins the
  lock. Simultaneous launches elect exactly one primary (tested with six).
* Socket paths are limited to ~100 bytes (`sun_path`); a longer path is a clear
  error. Production should use the OS app-runtime dir, not a temp dir.

## What is left for a production shell

1. **Confirm the shell technology against PKG 1**, then build and run the
   `src-tauri` layer: it is an unbuilt sketch (Tauri v2 API names unchecked,
   no icons, no `tauri.conf.json`, no initial status page load, tray quit calls
   the blocking dialog from the menu thread).
2. **Run against a real release.** `SHELL_RELEASE_DIR=<release> cargo run -p
   arbiter-shell-core --bin headless` is the hand check; verify in particular
   that SIGTERM to `bin/wardmast start` reaches the BEAM (it should: the start
   script `exec`s) and that shutdown fits the grace on a loaded box. Prefer
   `bin/wardmast stop` (distributed `init:stop`) if SIGTERM proves unreliable.
3. **Credentials (PKG 9):** SECRET_KEY_BASE, the Cloak key and an API token
   for the drain check, from the OS keychain; without a token every Quit asks.
4. **Data and logs:** a data dir (`WARDMAST_DATA_HOME`), release output to a
   rotating log file (the ring buffer is lost on shell exit), and a "show logs"
   menu item.
5. **Windows:** single-instance needs a named pipe or mutex; signals need
   `CTRL_BREAK`/`bin/wardmast stop`. Not attempted. macOS and Linux share the
   code but only Linux was run.
6. **Shell crash/upgrade story:** if the shell is SIGKILLed the release is
   orphaned (own process group); the next shell would find the port taken, pick
   another, and start a second server on the same database. Needs a pidfile or
   adopt-existing-release check, and ties into the in-app updater (PKG 14).
7. **Login-item/autostart, notifications, signing/notarisation, tray icons and
   a real error UI** (retry with details, "copy diagnostics" using the PKG 16
   support bundle).
8. **CI:** `cargo test` in `desktop/` is not wired into any workflow (workflow
   files are outside what this task could change); add a job on Linux and macOS.

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
    release_lock     pidfile + launch lock: adopt-or-refuse an orphaned release
    status_page the HTML shown while there is no dashboard (boot failure!)
    bin/fake_release   stand-in server for tests
    bin/headless       windowless shell driven over stdin/stdout (smoke test)
  src-tauri/    Tauri window + tray over shell-core (type-checked, never run;
                see "How it was verified")
```

**Shell technology: Tauri** (operator decision 2026-11-20; PKG 1 bd-5n0b4w
closed without a recorded choice), for macOS + Linux and Windows later from one
shell. The Rust `shell-core` carries every lifecycle rule and is covered by
tests that do not depend on the GUI layer.

## How it was verified

`cd desktop && cargo test` (~2 s; needs only a Rust toolchain, no
webview). Verified on Linux; the Unix-only pieces (`flock`, unix sockets,
`SIGTERM`) are shared with macOS but macOS was not run.

* Unit and integration tests run the supervisor against `fake_release`, a small
  binary that binds `$WARDMAST_PORT` and answers `/api/version` and
  `/api/scheduler/status`, with env switches for crash / hang / boot failure /
  ignore-SIGTERM / N workers in flight.
* `tests/headless.rs` is the scripted smoke test: it runs the real `headless`
  binary as separate OS processes (two launches, close, quit, boot failure).
* **The Tauri layer (`src-tauri`) was type-checked, not built or run.** Its
  Linux build needs WebKitGTK/GTK dev packages and `pkg-config`, none of which
  exist in the sandbox this was written in (`cargo check` stops in `glib-sys`).
  What was done instead: `cargo check --target aarch64-apple-darwin` in
  `desktop/src-tauri` (macOS needs no system webview libraries; one crate's C
  build step was stubbed with a no-op `cc`/`ar`, which `check` never links).
  It compiles `main.rs` against the real Tauri 2 API, including
  `generate_context!` over `tauri.conf.json`; a deliberately wrong call made it
  fail, so the check is not vacuous. A real `cargo tauri dev` / build on a
  machine with the webview toolchain is still to be done.
* **Not exercised:** a real `mix release` bundle; the window, tray and dialog
  actually running. See [What is left](#what-is-left-for-a-production-shell).

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

### Orphaned release (shell crash)

The release runs in its own process group, so a SIGKILLed or crashed shell
leaves it running and holding the database. Without a record the next shell
would find the port taken, pick another and start a **second server on the same
data home**. `release_lock.rs` plus the supervisor's `claim` step prevent that
(PKG 26, bd-d6jdq8). Active when `Config::data_home` is set (the Tauri shell sets
it from `WARDMAST_DATA_HOME` / `ARB_DATA_HOME` / `~/.wardmast`, the same chain as
`Wardmast.Env.data_home/0`, and passes it on to the release).

* **Pidfile** `<data home>/desktop-release.json` = `{"pid","port","version"}`,
  written atomically right after the shell spawns the release (before readiness)
  and removed when the shell stops it or sees it exit. If the record cannot be
  written the launch fails (the protection would be gone).
* **Launch lock** `<data home>/desktop-release.lock`: an exclusive `flock` held
  only for the launch decision (read record, adopt / replace / spawn, write the
  new record). It is what makes two shells started at once produce one server:
  the second waits, then finds the first one's live record and adopts it. It is
  not held for the release's lifetime: a flock dies with the shell, the release
  does not, so only the pid says whether the database is in use.
* **On every launch, under the lock:**

  | Record | Action |
  | --- | --- |
  | none / unreadable | start a release |
  | pid dead (stale) | delete the record, start a release |
  | pid alive, `/api/version` reports the expected version | **adopt**: show the dashboard on the recorded port, start nothing |
  | pid alive, different version | SIGTERM it, wait up to `stop_grace` for its own orderly shutdown (workers drain, 15 s each), SIGKILL the group only after that, then start the new release |
  | pid alive, never answers (`ready_timeout`) or answers as something other than a release | **refuse**: `BootFailed` naming the pid and the pidfile. Never started a second server, never killed a pid on a guess (it may have been reused by an unrelated process) |

  A release that is still booting (its shell died in the boot window) is waited
  for while its pid lives, up to `ready_timeout`.
* An adopted release is watched by pid (there is no `Child` to wait on) and
  stopped on Quit exactly like one the shell spawned; if it dies the shell
  relaunches it under the usual backoff. Its output is not captured (it
  belongs to the dead shell's pipes).
* The expected version comes from the bundle's `releases/start_erl.data`
  (`release_lock::bundled_version`); `None` adopts whatever is running.
* **Drain-aware replacement** means SIGTERM and the server's own drain, bounded
  by `stop_grace`. The shell does not read the scheduler status here (it has no
  token yet, PKG 9) and has no prompt at launch, so a version replacement does
  not ask; in-flight workers are interrupted and resumed like on any Quit. The
  in-app updater (PKG 14) can call the same stop-and-relaunch path.
* Known limits: pid reuse is guarded only by requiring the recorded port to
  answer as a release before anything is signalled; a pidfile that was deleted
  by hand while a release runs cannot be detected (the port probe and the
  release's own bind failure still catch the common case); Windows is not
  covered (see item 5 below).

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

1. **Build and run the `src-tauri` layer** with the webview toolchain
   (`cargo tauri dev`): it only type-checks so far. Placeholder icons (the brand
   mark) and `tauri.conf.json` are in place; missing are bundling/signing
   config, an app-runtime-dir socket path, and routing the OS-level quit
   (Cmd+Q, `RunEvent::ExitRequested`) through `request_quit` so it cannot
   bypass the drain prompt.
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
6. **Shell crash/upgrade story:** done for the orphaned release (pidfile + launch
   lock, adopt-or-refuse, see [Orphaned release](#orphaned-release-shell-crash)).
   Still open: calling the same stop-and-relaunch path from the in-app updater
   (PKG 14), and running it against a real release (item 2).
7. **Login-item/autostart, notifications, signing/notarisation, tray icons and
   a real error UI** (retry with details, "copy diagnostics" using the PKG 16
   support bundle).
8. **CI:** `cargo test` in `desktop/` is not wired into any workflow (workflow
   files are outside what this task could change); add a job on Linux and macOS.

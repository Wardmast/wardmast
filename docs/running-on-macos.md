# Running Arbiter on macOS (dev mode)

macOS support is **phase 1, dev mode**: you run the coordinator from a source
checkout, supervised by a per-user LaunchAgent. There is no release install and
no system-wide service yet. Several Linux-only isolation features are absent;
see [Limitations](#limitations).

## Prerequisites

- A source checkout of this repo (`mix.exs` + `apps/` at the root).
- Elixir/Erlang and the repo's other dev dependencies on your `PATH`
  (for example via Homebrew or asdf). `arb install service` captures your
  current `PATH` so the agent can find them: launchd itself starts agents with
  a minimal `PATH`.
- `git`, plus the agent CLIs you intend to dispatch workers to.

## Install under a LaunchAgent from a source checkout

From inside the checkout (or with `ARB_HOME` pointing at it):

```sh
arb install service
```

This:

1. Records the checkout as the project root, so `arb start/restart/update`
   resolve it from any directory.
2. Writes `<arbiter_home>/wardmast.env` (captured secrets and `PATH`) and the
   wrapper `<arbiter_home>/launchd-run.sh`, which loads that env file and then
   `exec`s the checkout's `.run-server.sh`.
3. Writes `~/Library/LaunchAgents/com.wardmast.server.plist` and loads it into
   your `gui/<uid>` launchd domain (`launchctl bootstrap` + `enable`).

The agent has `RunAtLoad` and `KeepAlive = {SuccessfulExit = false}`: it starts
at login and is respawned after a crash (10 s throttle), but a clean exit or
`bootout` leaves it stopped. Output goes to `<arbiter_home>/log/wardmast.log`.

Refused with an explanatory message: `--system`, and running from a directory
that is not a source checkout.

### Day-to-day

| Command | Effect |
| --- | --- |
| `arb restart` | `launchctl kickstart -k` (bootstraps the plist if not loaded) |
| `launchctl bootout gui/$(id -u)/com.wardmast.server` | Stop the service (unloads the job so `KeepAlive` does not respawn it) |
| `launchctl print gui/$(id -u)/com.wardmast.server` | Show service state |
| `arb install service --uninstall` | unloads the job and removes the plist (idempotent) |

Re-run `arb install service` after changing `PATH` or secrets to refresh
`wardmast.env`.

## Limitations

| Area | macOS dev mode | Linux |
| --- | --- | --- |
| Terminal sessions (`arb-session-*`) | **Supported, without a scope.** Each session is a detached tmux server (`Wardmast.Sessions.Runner.Darwin`) in `/tmp/arb-<hash>/sessions` (short, `0700`: macOS's 104-byte socket limit rules out `$TMPDIR`), tracked by a pidfile plus `tmux has-session`. They survive a server restart (`AbandonProcessGroup = true`) and are re-adopted at boot. A stop is `tmux kill-server` + `SIGTERM`, not a cgroup kill, so a deliberately `nohup`-ed grandchild can outlive it. `arb session list` / `attach` work with the server down. | Supported (systemd scope) |
| Worker sandbox | **None.** Workers run unconfined as your user. | bwrap sandbox |
| Per-worker memory cap | **None.** There is no cgroup equivalent, so a runaway worker is not capped. | systemd cgroup limits |
| `:strict` isolation mode | **Unavailable**, because it depends on the sandbox. | Available |
| Workers surviving a server restart | **No.** The plist sets `AbandonProcessGroup = true` (so detached terminal sessions survive), which means launchd no longer kills the group; the server's own shutdown and the boot-time orphan sweep reap each worker's process group instead. Re-run `arb install service` to refresh an older plist that still says `false`. | Supported |
| Start before login | **No.** A LaunchAgent starts at login. | `loginctl enable-linger` |
| Log rotation timers | Not installed. | logrotate timers |
| System scope (`--system`) | Refused. | Supported |
| Release install | Not supported; dev checkout only. | Supported |

Because there is no sandbox or memory cap, only dispatch work you trust to a
macOS coordinator, and keep an eye on memory use.
See [worker-security.md](worker-security.md) and
[worker-memory-cap.md](worker-memory-cap.md) for what those controls do on Linux.

## Troubleshooting

- Service not starting: read `<arbiter_home>/log/wardmast.log` and
  `launchctl print gui/$(id -u)/com.wardmast.server`.
- Tools not found: re-run `arb install service` from a shell where they are on
  `PATH`.

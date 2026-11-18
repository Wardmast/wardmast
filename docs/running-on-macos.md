# Running Wardmast on macOS (dev mode)

macOS support has two shapes: **dev mode** (run from a source checkout under a
per-user LaunchAgent) and a **release install** (the prebuilt Apple Silicon
tarball, see [Release install](#release-install-apple-silicon)). There is no
system-wide service. Several Linux-only isolation features are absent;
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

## Release install (Apple Silicon)

Each tagged release publishes `arbiter-<tag>-darwin-arm64.tar.gz` and its
`.sha256` on the GitHub Release. Only arm64 is published; Intel Macs must use
dev mode. The tarball is the OTP release tree (no Erlang/Elixir needed), its
Mach-O files are **ad-hoc codesigned** (not notarized or Developer-ID signed),
and it contains no systemd unit.

```sh
TAG=vX.Y.Z
D="$HOME/.wardmast"                     # the data home
mkdir -p "$D/releases/$TAG"
cd "$(mktemp -d)"
gh release download "$TAG" -R <owner>/<repo> -p "arbiter-$TAG-darwin-arm64.tar.gz*"
shasum -a 256 -c "arbiter-$TAG-darwin-arm64.tar.gz.sha256"
tar -xzf "arbiter-$TAG-darwin-arm64.tar.gz" -C "$D/releases/$TAG"
ln -sfn "releases/$TAG" "$D/current"
```

Then install the `arb` CLI from the same release and register the service:
`arb install service` writes the LaunchAgent so it runs
`<data-home>/current/bin/wardmast start`. Verify with `arb doctor`.

### Gatekeeper / quarantine (`xattr`)

Files downloaded through a browser get the `com.apple.quarantine` attribute, and
Gatekeeper then blocks unnotarized binaries ("cannot be opened because the
developer cannot be verified"). The release job strips extended attributes
before archiving, but **your download** is quarantined if a browser (or another
quarantine-aware app) fetched it. `curl`, `gh` and `arb server deploy` do not
set the attribute.

If you downloaded in a browser, clear it on the unpacked tree before first run:

```sh
xattr -dr com.apple.quarantine "$HOME/.wardmast/releases/$TAG"   # or: xattr -cr
xattr -lr "$HOME/.wardmast/releases/$TAG" | head                 # expect no output
codesign --verify --strict "$HOME/.wardmast/releases/$TAG/bin/wardmast"
```

Do not disable Gatekeeper system-wide, and only clear attributes on files you
verified against the `.sha256`.

### Upgrade

Preferred: `arb server deploy` (see [self-update.md](self-update.md)). It
downloads and checksum-verifies the `darwin-arm64` tarball, backs up the
database, swaps `current`, restarts the service and health-checks it, keeping
the previous 3 releases. The dashboard's "Update" button launches it via
`systemd-run` and is Linux-only; on macOS run the CLI yourself.

Manual: unpack the new tag beside the old one (steps above, including the
`xattr` clear if needed), back up the database while the service is stopped,
repoint `current`, then `arb restart`.

### Rollback

`arb server deploy` rolls back automatically when the new release does not come
back healthy, restoring the pre-deploy database backup when the release added
migrations; see [self-update.md](self-update.md#rollback-and-restoring-the-backup).
To roll back by hand:

```sh
launchctl bootout gui/$(id -u)/com.wardmast.server      # stop first
cp "$D/snapshots/wardmast-pre-$TAG-<utc>.sqlite3" <database path>   # only if the new release ran migrations
ln -sfn "releases/<previous-tag>" "$D/current"
arb restart
```

Never restore a backup under a running server, and move the failed database
aside rather than deleting it.

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
| Release install | Apple Silicon (`darwin-arm64`) only; see [Release install](#release-install-apple-silicon). | Supported |

Because there is no sandbox or memory cap, only dispatch work you trust to a
macOS coordinator, and keep an eye on memory use.
See [worker-security.md](worker-security.md) and
[worker-memory-cap.md](worker-memory-cap.md) for what those controls do on Linux.

## Troubleshooting

- Service not starting: read `<arbiter_home>/log/wardmast.log` and
  `launchctl print gui/$(id -u)/com.wardmast.server`.
- Tools not found: re-run `arb install service` from a shell where they are on
  `PATH`.

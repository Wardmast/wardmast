# Running Wardmast on macOS (dev mode)

macOS support has two install shapes and two service shapes. **Dev mode** runs
from a source checkout; a **release install** is the prebuilt Apple Silicon
tarball (see [Release install](#release-install-apple-silicon)). The service
is either a per-user **LaunchAgent** (the default, for one developer) or, on a
shared team Mac, a system-wide **LaunchDaemon** (see
[Team Mac: system-wide LaunchDaemon](#team-mac-system-wide-launchdaemon)).
Several Linux-only isolation features are absent; see [Limitations](#limitations).

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

Refused with an explanatory message: installing while a system-wide
LaunchDaemon exists (see below), and running from a directory that is not a
source checkout without a release install.

### Day-to-day

| Command | Effect |
| --- | --- |
| `arb restart` | `launchctl kickstart -k` (bootstraps the plist if not loaded) |
| `launchctl bootout gui/$(id -u)/com.wardmast.server` | Stop the service (unloads the job so `KeepAlive` does not respawn it) |
| `launchctl print gui/$(id -u)/com.wardmast.server` | Show service state |
| `arb install service --uninstall` | unloads the job and removes the plist (idempotent) |

Re-run `arb install service` after changing `PATH` or secrets to refresh
`wardmast.env`.

## Team Mac: system-wide LaunchDaemon

For a shared Mac (for example a Mac mini that a team uses for Apple
development) run Wardmast as a **LaunchDaemon**: it starts at boot, before
anyone logs in, and runs as a dedicated, unprivileged service account rather
than as whoever happens to be logged in. The free single-developer install
stays the per-user LaunchAgent above; the daemon is the team-tier shape (a
Linux team host uses the systemd system service, `sudo ward install service
--system`, instead).

### Set up

1. **Create the service account** (once; the installer will not create
   accounts). It needs a home directory, which is where the data lives, and
   no login. The example below is not run by the installer; check it against
   your macOS version before using it:

   ```sh
   sudo sysadminctl -addUser _wardmast -fullName "Wardmast service" \
     -home /Users/_wardmast -shell /usr/bin/false -password -
   sudo createhomedir -c -u _wardmast   # if /Users/_wardmast was not created
   ```

   Hide it from the login window if you like
   (`sudo dscl . create /Users/_wardmast IsHidden 1`).

2. **Install**, as root (the daemon itself never runs as root):

   ```sh
   sudo ward install service --system                    # account _wardmast
   sudo ward install service --system --service-user ci  # or another account
   ```

3. **Deploy a release** into the account's data home, as that account. A
   daemon is release mode only; it never runs out of someone's checkout:

   ```sh
   sudo -H -u _wardmast ward server deploy
   ```

4. **Verify**: `sudo launchctl print system/com.wardmast.server`, then
   `ward doctor`: the `launchd mode` check reports `daemon mode` and the
   account (the agent reports `agent mode`).

What `--system` does, in order: refuses unless root; refuses `root` or any
uid-0 account as the service user; refuses while the per-user LaunchAgent is
installed (two servers would fight over the one port; remove one first);
creates `<service home>/.wardmast` (mode `0700`, owned by the account);
captures secrets and `PATH` into its `wardmast.env`; writes the env-sourcing
wrapper; writes the plist; creates the log directory; `launchctl bootstrap
system`. Re-running is idempotent. `sudo ward install service --system
--uninstall` unloads and removes the plist only. The account, its data and
the logs stay. Installing the per-user agent while the daemon exists is
refused the same way.

Secret capture reads the *installing* environment, and `sudo` strips most of
it, so expect to add API keys and tokens to
`<service home>/.wardmast/wardmast.env` yourself (or use the `*_REF` secret
manager pointers, see [secrets-at-rest.md](secrets-at-rest.md)). The captured
`PATH` is root's; make sure the Homebrew directories are on it
(`ward doctor` checks).

### Where things live

| Thing | Agent (default) | Daemon (`--system`) |
| --- | --- | --- |
| Plist | `~/Library/LaunchAgents/com.wardmast.server.plist` | `/Library/LaunchDaemons/com.wardmast.server.plist`, `root:wheel`, `0644` |
| launchd domain | `gui/<uid>` | `system` |
| Runs as | the logged-in user | `UserName`/`GroupName` of the service account |
| Starts | at login | at boot |
| Data home | `~/.wardmast` | `<service home>/.wardmast`, `0700`, service account only |
| Log | `<data home>/log/wardmast.log` | `/Library/Logs/Wardmast/wardmast.log` (`0750`, service account) |
| Restart / stop | `arb restart`, `launchctl bootout gui/<uid>/…` | `sudo launchctl kickstart -k system/com.wardmast.server`, `sudo launchctl bootout system/com.wardmast.server` |

`ward restart` run without root against a daemon stops with a "needs root"
hint (the `sudo launchctl kickstart -k` command) and does not touch launchd.

### Security model on a multi-user host

The point of the daemon is a service that does not belong to any one person's
login. Read these before putting it on a shared machine:

- **Data is private to the service account.** The data home is `0700`: the
  database, `wardmast.env` (captured secrets) and the run directory are not
  readable by the host's other users. Operators read logs with `sudo`
  (`/Library/Logs/Wardmast` is `0750`).
- **The plist is the privilege boundary.** launchd only trusts a daemon plist
  that is root-owned and not group/world-writable, which is how the installer
  writes it; `ward doctor` warns if it is not, and warns if a daemon plist
  has no unprivileged `UserName` (launchd would then run it as root). Whoever
  can write the plist can run code as root at next boot; whoever can write
  the wrapper script can run code as the service account. Keep admin rights
  to the few people who need them.
- **Workers run as the service account, unconfined.** macOS has no sandbox, no
  egress filter and no per-worker memory cap (see [Limitations](#limitations)),
  so every worker has the service account's full file access, and every team
  member's work shares that one account. Do not put secrets on the host that
  you would not give every dispatching teammate, and run untrusted workloads
  on a Linux node.
- **Operator proof, and who counts as the operator.** Minting a coordinator
  token (`ward mcp token mint`, dashboard login) requires *operator proof*
  (see [worker-security.md](worker-security.md#operator-proof-for-token-minting-bd-8381tk)):
  a local Unix socket that accepts only a caller with the **same Unix user as
  the server** that the server itself did not start. In daemon mode the
  server's user is the service account, so a team member's own login is a
  *foreign uid* and is refused by design: being an admin on the box is not
  operator proof. Operator actions are performed *as the service account*,
  from outside the server's process tree (`sudo -H -u _wardmast ward mcp token
  mint`), which makes "who may be operator" an explicit `sudoers` decision
  instead of an accident of who is logged in.
  On macOS the socket identifies the caller with `LOCAL_PEERCRED` (uid) and
  `LOCAL_PEERPID` (pid), walks its ancestry with `ps`, and recognizes a
  session's processes by the tmux server pid in the session's pidfile
  (bd-5tg348; see [worker-security.md](worker-security.md#on-macos-bd-5tg348)).
  There is no cgroup, so a worker's double-forked orphan is **not** refused:
  on a Mac, operator proof is a guardrail against the paths an agent normally
  takes, not a boundary.
  **Not verified on a Mac yet:** it was built and tested on Linux, with the
  macOS mechanism driven by an injected process table and by Linux's own
  `ps`. The macOS CI job runs the portable tests after merge, and a run on a
  real Mac is still owed. The `sudo -u` model above describes the intended
  boundary, not behaviour confirmed on macOS.
- **Remote access** is unchanged: bind to loopback and use SSH or the
  documented token login (see [remote-access.md](remote-access.md)); do not
  expose the port to the team LAN without it.

### Not verified here

The installer, plist and doctor check are covered by unit tests with a stubbed
`launchctl`/`dscl`/`chown` runner; none of it has been run against a real
launchd. Before relying on it, run through the steps above once on the
target Mac and confirm `sudo launchctl print system/com.wardmast.server`
shows `state = running` and the process owner is the service account.

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

### Running `ward` without a system Erlang

The tarball carries `bin/ward` (a launcher) and `bin/ward.escript` (the CLI),
plus `bin/no_dot_erlang.boot`. The launcher runs the CLI on the release's
bundled erts and sets the `RELEASE_LIB` boot variable, so no `ERL_FLAGS` or
manual file copies are needed and nothing has to be on `PATH`:

```sh
"$D/current/bin/ward" --version
ln -sf "$D/current/bin/ward" "$HOME/.local/bin/ward"   # optional; symlinks are resolved
```

Running the bare `ward` escript directly needs an Erlang on `PATH`; with only
the release's `erts-*/bin` on `PATH` it dies with `cannot get bootfile …
no_dot_erlang.boot`. Use `bin/ward` instead (set `WARD_ESCRIPT` to point it at a
different escript). The release workflow runs
`scripts/check-release-ward.sh` on both the Linux and macOS builds to keep this
working.

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
| Per-worker memory cap | **Optional, best-effort.** There is no cgroup equivalent, so nothing is enforced by the kernel. Set `WARDMAST_WORKER_MEMORY_MAX` (e.g. `12G`, `40%`) and a watchdog polls the RSS of each worker's process group every 5 s and kills the group over the cap, recording `memory_cap_exceeded`. Off unless set; see [worker-memory-cap.md](worker-memory-cap.md#on-macos-an-optional-rss-watchdog). A runaway can outgrow the cap between polls. | systemd cgroup limits (default 40% of RAM) |
| Operator proof (`ward mcp token mint`, dashboard login) | **Supported, without the cgroup check.** The peer comes from `LOCAL_PEERCRED`/`LOCAL_PEERPID`, its ancestry from `ps`, and sessions from their pidfiles. A worker's double-forked orphan is reparented to launchd and is not refused. See [worker-security.md](worker-security.md#on-macos-bd-5tg348). | Ancestry, service cgroup and session scope |
| `:strict` isolation mode | **Unavailable**, because it depends on the sandbox. | Available |
| Workers surviving a server restart | **No.** The plist sets `AbandonProcessGroup = true` (so detached terminal sessions survive), which means launchd no longer kills the group; the server's own shutdown and the boot-time orphan sweep reap each worker's process group instead. Re-run `arb install service` to refresh an older plist that still says `false`. | Supported |
| Start before login | **Agent: no** (it starts at login). **Daemon: yes** (starts at boot), see [Team Mac](#team-mac-system-wide-launchdaemon). | `loginctl enable-linger` |
| Log rotation timers | Not installed. | logrotate timers |
| System scope (`--system`) | A system-wide LaunchDaemon, release mode only; see [Team Mac](#team-mac-system-wide-launchdaemon). | Supported |
| Release install | Apple Silicon (`darwin-arm64`) only; see [Release install](#release-install-apple-silicon). | Supported |

Because there is no sandbox and the memory cap is optional and approximate, only
dispatch work you trust to a macOS coordinator, and keep an eye on memory use.
See [worker-security.md](worker-security.md) and
[worker-memory-cap.md](worker-memory-cap.md) for what those controls do on Linux.

## Provider CLIs and the server's PATH

The server detects `claude`, `codex` and `agy`/`gemini` (installed? where? which
version?) and shows the result on the Providers page and in
`ward server doctor`. Each provider has a minimum supported version
(`Wardmast.Agents.CliDetection`; override with
`config :wardmast, Wardmast.Agents.CliDetection, min_versions: %{"codex" => "..."}`):
dispatch to a provider whose CLI is below it is refused with the installed and
the required version. A missing or outdated CLI shows the vendor's documented
install/upgrade command on the Providers page, to copy and run yourself;
Wardmast never runs an installer.

A server started from a GUI session (a LaunchAgent, a desktop entry) inherits
only `/usr/bin:/bin:/usr/sbin:/sbin`. When the `PATH` it starts with holds
nothing else, it asks your login shell once at boot (`$SHELL -l -i -c`, 5 s
timeout, `/bin/zsh` if `SHELL` is unset) for the `PATH` your rc files build and
uses it for CLI detection and for every spawn. A richer `PATH` is never
replaced. `ward server doctor` shows `server PATH` when this happened, or a
warning when the shell gave no answer.

## Troubleshooting

- Service not starting: read `<arbiter_home>/log/wardmast.log` and
  `launchctl print gui/$(id -u)/com.wardmast.server`.
- Tools not found: re-run `arb install service` from a shell where they are on
  `PATH`.

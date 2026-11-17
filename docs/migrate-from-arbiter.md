# Migrating an Arbiter install to Wardmast

The project was renamed from Arbiter to Wardmast. A fresh install uses `~/.wardmast`,
`wardmast.service` and `wardmast.env`; an install made before the rename still has
`~/.arbiter`, `arbiter.service` and `arbiter.env`. `scripts/migrate-from-arbiter.sh`
moves one host across in a single idempotent step. There is no multi-version
compatibility beyond the one-release `ARB_*` / `ARBITER_*` environment fallback
(`Wardmast.Env`): after the migration nothing reads the old paths or unit names.

## A host install (laptop / the box running the primary)

```sh
systemctl --user stop arbiter.service         # the script refuses while it is running
scripts/migrate-from-arbiter.sh --dry-run     # optional: print what would change
scripts/migrate-from-arbiter.sh
systemctl --user start wardmast.service
ward doctor
```

What it does (each step checks its own precondition, so re-running is safe and a
finished migration is a no-op):

| Before | After |
| --- | --- |
| `~/.arbiter/` (DB, releases, snapshots, logs) | `~/.wardmast/`, with `~/.arbiter` left as a compat symlink |
| `~/.arbiter/current -> /home/x/.arbiter/releases/vN` | repointed at `~/.wardmast/releases/vN` |
| `arbiter.env` | `wardmast.env`, mode 0600, original kept as `wardmast.env.pre-migrate` |
| `ARB_*` / `ARBITER_*` operator keys (incl. `ARB_PRIMARY_CHECKOUT`), `<home>/.arbiter` inside values | `WARDMAST_*` keys, `<home>/.wardmast` |
| `log/arbiter.log`, logrotate config | `log/wardmast.log`, updated config |
| `~/.config/systemd/user/arbiter.service` + `arbiter.service.d/` + `arbiter-logrotate.*` | `wardmast.service` + drop-ins + `wardmast-logrotate.*` (transformed from your files, so local tuning survives); the old ones are disabled and parked as `*.pre-wardmast` |
| `~/.config/arbiter/home` | `~/.config/wardmast/home` |
| the checkout's `.arbiter.env` / `.run-server.sh` | `.wardmast.env`, `.run-server.sh` sourcing it |

Left alone on purpose: variables the server exports to workers and the CLI
(`ARB_TOKEN`, `ARB_NODE_*`, `ARBITER_MCP_TOKEN`, ...), the database file name
(`arbiter.sqlite3`, now inside `~/.wardmast`), `~/.cache/arbiter` (worker scratch),
and the remote-host node agent (`~/.arbiter-node`, `arbiter-node.service`), which is
a separate install on other machines.

It refuses (exit 1, nothing touched) when `arbiter.service` or `wardmast.service` is
active, when the data home's pid file names a live server, or when both `~/.arbiter` and
`~/.wardmast` are real directories (decide which is live and merge by hand).

A system-wide unit (`/etc/systemd/system/arbiter.service`) is reported, not migrated
(the script never uses sudo): stop and disable it, then `ward install service --system`.

Rollback before you start the new unit:

```sh
rm ~/.arbiter                                   # the compat symlink
mv ~/.wardmast ~/.arbiter
ln -sfn ~/.arbiter/releases/<vN> ~/.arbiter/current   # `current` was repointed at ~/.wardmast/...
cp ~/.arbiter/wardmast.env.pre-migrate ~/.arbiter/arbiter.env   # the env file goes back under its old name
# rename ~/.arbiter/log/wardmast.log* back to arbiter.log*
# restore each *.pre-wardmast unit file under ~/.config/systemd/user/ to its original name
```

## A cluster install (helm)

The chart is now `wardmast-node`, the controller image `ghcr.io/<owner>/wardmast-controller`,
the worker base image `ghcr.io/<owner>/wardmast-worker-base`, every Kubernetes object
`wardmast-*` and pod labels `wardmast.dev/*`; a new install defaults to the
`wardmast-workers` namespace. Upgrading an existing `arbiter-node` release is a
manual sequence (copy the credential Secrets with Helm ownership metadata, delete the old Deployment, upgrade, verify)
because object names and the Deployment selector changed:

```sh
scripts/migrate-from-arbiter.sh --helm-notes
```

An existing install keeps its namespace (a namespace cannot be renamed; the chart does
not hard-code one). The tailscale ACL tag `tag:arbiter-node` is unchanged — it lives in
your tailnet policy.

## Upgrading v0.4.x -> v0.5+ with `arb server deploy`

Releases before the fix for #1425 could crash at the very end of
`arb server deploy` when run from the `arb` escript: the CLI self-update
replaced `~/.local/bin/arb` with the deprecation shim while that file was still
running. The server side is fine (swapped, restarted, health-checked), but
`deploy-status.json` stays at `running` / `updating cli`, and
`ward server doctor` warns `deploy of vX was interrupted ... updating cli`.

If you hit that: run `ward server doctor` and ignore the "interrupted ...
updating cli" warning when the server is otherwise healthy, or re-run the
deploy with `ward server deploy --version <tag>`. Newer CLIs defer the shim
until the deploy report and final status are written.

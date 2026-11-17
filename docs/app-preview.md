# App preview

See what a worktree is doing: run a ticket's checkout as a live app, on a port
that cannot clash with the live server, other worktrees or other repos, and
open it in a browser.

```
ward preview start bd-1a2b3c        # prints http://127.0.0.1:31004/ once the app answers
ward preview list
ward preview logs bd-1a2b3c -f
ward preview stop bd-1a2b3c
```

The dashboard has the same thing: a **Preview** panel on the ticket page (and
the worker page) with a button, the state (starting / running with a clickable
URL / failed with its log tail) and a Stop button, plus a **Previews** list on
the Workers page. MCP: `preview_start`, `preview_stop`, `preview_list`,
`preview_logs`. REST: `/api/previews`.

## Configuration

Per repo, under `worker.repos.<repo>.preview`; a workspace-wide
`worker.preview` supplies defaults the repo block merges over (a map merges key
by key, `env` included). Validated when the config is written: unknown keys and
bad values are refused (`ward config set` / `workspace_config_set`).

| key | default | |
|---|---|---|
| `command` | — (required) | The startup script, run from the checkout root. |
| `setup` | none | Run once per preview checkout before the first start. |
| `port_env` | `PORT` | The variable set to the allocated port. |
| `env` | `{}` | Extra variables. |
| `ready_path` | `/` | Probed (`GET`) before the URL is reported; any answer below 500 is ready. |
| `ready_timeout` | `60` | Seconds to wait for it (max 3600). A preview that is not ready in time is stopped and marked failed. |
| `port_range` | `"31000-31999"` | Where ports come from: `"lo-hi"` or `[lo, hi]`. |
| `idle_ttl_seconds` | `7200` | Auto-stop after this long untouched. |

`command`, `setup` and `env` values may use `{{port}}`, `{{task_id}}`,
`{{checkout}}` and `{{host}}` (`127.0.0.1`) — for an app that takes its port as
a flag (`--port {{port}}`), or a per-preview database
(`DATABASE_PATH=/tmp/preview-{{task_id}}.sqlite3`). An unknown `{{name}}` is
refused.

The preview runs with the same scrubbed environment worker children get
(`Wardmast.Worker.SpawnEnv`): the server's own `PORT`, `DATABASE_PATH` and
secrets are never inherited — only what `env` and `port_env` set, plus
`WARDMAST_PREVIEW=1`.

### Phoenix repo — this one

```json
{
  "worker": {
    "repos": {
      "arbiter": {
        "preview": {
          "setup": "mix deps.get && MIX_ENV=dev mix ecto.setup",
          "command": "mix phx.server",
          "env": {
            "DATABASE_PATH": "/tmp/preview-{{task_id}}.sqlite3",
            "SECRET_KEY_BASE": "preview-only-not-a-secret-preview-only-not-a-secret-preview-only-0000",
            "WARDMAST_CLOAK_KEY": "…a throwaway base64 key…"
          },
          "ready_path": "/",
          "ready_timeout": 180
        }
      }
    }
  }
}
```

`config/dev.exs` reads `PORT`, so the default `port_env` is right. Use a
per-preview `DATABASE_PATH`: a preview must never open the live database.
First start compiles the app (`ready_timeout`).

### Postgres-backed repo

```json
{
  "worker": {
    "repos": {
      "shop": {
        "preview": {
          "setup": "mix deps.get && mix ecto.create && mix ecto.migrate",
          "command": "mix phx.server",
          "port_env": "PORT",
          "env": {
            "DATABASE_URL": "ecto://postgres:postgres@localhost/shop_preview_{{task_id}}",
            "PHX_HOST": "127.0.0.1"
          },
          "ready_path": "/health",
          "ready_timeout": 120
        }
      }
    }
  }
}
```

The database name carries the ticket id, so two previews never share one.
`ecto.create` is a no-op when it exists. Nothing drops it: remove stale
`shop_preview_*` databases yourself, or add a `dropdb` to your own cleanup.

For a Node app: `"command": "npm run dev -- --port {{port}} --host {{host}}"`.

## Port isolation

Ports come from a persisted lease table (`preview_leases`), keyed by
`(repo, task_id)`, with a **unique index on `port`**: two previews can never
hold one, across repos, tickets and workspaces. A candidate must also

- lie in `port_range`, which is refused when it overlaps the worker dev-server
  range 20000–29999 (`Wardmast.Worker.DevServerEnv`);
- not be the server's own port, or one already leased;
- pass a bind probe on `127.0.0.1`.

Stop (or a failure, or the auto-stop below) releases the lease. Previews are
reached on `127.0.0.1` only; the app has to bind there (Phoenix dev does).
Exposing one over a tailnet is out of scope.

## Which checkout it runs in

A preview **never modifies a worker's checkout**:

| situation | runs from |
|---|---|
| the ticket's checkout is on this machine and no worker is live in it | the checkout itself (`worktree`) |
| a worker is live in it | a clone of its `HEAD` under the preview directory (`snapshot`; uncommitted edits are not included — the UI and CLI say so) |
| the ticket's run was placed on a cluster/machine node | a **read-only checkout of the branch's pushed head**, fetched on the primary (`remote_head`) |
| the ticket has no checkout here | the pushed head, as above; an error if the branch was never pushed |

A preview checkout is a detached `git clone --local` with its `origin` remote
removed: it has no way to push. It is rebuilt on every start, so `setup` runs
again for it.

## Process supervision and logs

The command runs as `sh -c <command>` leading its own process group, owned by a
supervised `Wardmast.Preview.Runner`. **Stop kills the whole group** (TERM, then
KILL after a grace period) — a `mix phx.server` BEAM, a dev watcher and
whatever they spawned. A server shutdown stops running previews the same way.
If the server dies without shutting down, the next sweep marks the orphaned
rows failed and frees their ports; a process left listening is skipped by the
port probe.

The log (setup, startup, the app's output) is
`<preview_root>/<repo>/<task_id>/preview.log` (`~/.wardmast/previews`, or
`WARDMAST_PREVIEW_ROOT`). `ward preview logs <ticket> [-f]`, `preview_logs` and
the dashboard read it, also after a stop or a failure.

## Lifecycle

A preview stops on request, and automatically when

- the ticket closes or merges (the close hook stops it before the worktree is
  removed),
- the worktree it runs in is removed (a 30-second sweep),
- it has not been touched for `idle_ttl_seconds`. Starting, showing, or reading
  the log of a preview touches it; `ward preview start <ticket>` on a running
  preview just extends it.

## Not in v1

Previews on cluster nodes (the checkout is built on the primary), public or
tailnet exposure, and a Preview button on each worker-list row (the Workers page
lists running previews instead).

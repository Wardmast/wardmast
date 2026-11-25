# Per-worker memory cap and OOM policy

Incident 2026-10-03 (GitHub #265): a worker's child BEAM (a `mix test` in a
worktree) grew to 17.5 GB. The kernel OOM-killer picked it, and because every
worker lived in the server's own cgroup (`wardmast.service`, `OOMPolicy=stop`,
`MemoryMax=infinity`) systemd stopped the **whole service** — every in-flight run
died and the coordinator's MCP connection dropped. It happened twice in ten
minutes.

Two independent fixes ship together. Either alone helps; both close it.

## 1. Each agent spawn runs in its own capped scope

`Wardmast.Worker.MemoryScope` wraps every agent spawn (every provider, every
resume / nudge respawn) in a transient systemd scope:

```
systemd-run --user --scope --unit=arb-run-<task>-<hex> \
  -p MemoryMax=<cap> -p MemorySwapMax=0 -p OOMPolicy=kill \
  env -u XDG_RUNTIME_DIR <agent argv…>
```

The scope is a **sibling** of the service's cgroup, so the cap bounds the agent
and everything it spawns, and an OOM kills exactly that scope — agent and all —
while the server and every other worker carry on. `MemorySwapMax=0` is
deliberate: cgroup v2's `memory.max` counts RAM only, so without it a runaway
tree spills into swap and thrashes the host instead of being killed.

When it happens the run is recorded **failed** with stop category
`memory_cap_exceeded` and a reason of the form

> memory cap exceeded: the worker's process tree hit its per-worker limit
> (MemoryMax=12G, peak 12.0 GiB) and was OOM-killed …

(The agent's own exit status is a bare 137, the same as any SIGKILL. systemd
keeps the answer: the scope goes `failed` with `Result=oom-kill`, which the
Worker reads when the port exits and then `reset-failed`s.)

### Scopes die with the service

Because the scope is a sibling, systemd's `KillMode=control-group` no longer
sweeps the workers when the service stops. A graceful stop is covered by the
Worker's own teardown; a BEAM crash, a SIGKILL after `TimeoutStopSec`, or the
server's own BEAM being OOM-killed (now survivable under `OOMPolicy=continue`)
is not. Without more, those agents would keep running in their worktrees while
the boot-time resume started a second agent in the same tree. So when the server
runs as a user service, each scope is created with
`BindsTo=<unit>` and `After=<unit>` (the unit is read from the server's own
cgroup): the moment the service leaves the active state, systemd stops its
worker scopes. A shell-launched server has no unit and no binding. The capability
probe scope is never bound.

### Configuring the cap

| Setting | Meaning |
| --- | --- |
| `WARDMAST_WORKER_MEMORY_MAX` (e.g. in `~/.wardmast/wardmast.env`) | A size systemd accepts for `MemoryMax=`: `12G`, `512M`, or a percentage of physical RAM (`40%`). |
| `config :wardmast, :worker_memory_max, "12G"` | Same, for dev checkouts. The environment variable wins. |
| *(unset)* | `40%` of physical RAM, per worker. |
| `off` / `0` / `none` / `infinity` | No cap; workers spawn exactly as before. |

An unparseable value is logged and replaced by the default — it never silently
disables the protection. Changes need a server restart.

The cap applies to the **whole process tree** of one agent: `claude` itself
(~1 GB), plus a `mix test` BEAM, plus a dialyzer run, if the agent runs them at
the same time. Raise it if legitimate workloads hit it.

### When the cap cannot be applied

Needs Linux, systemd, cgroup v2, and a user manager that has the **memory
controller delegated** (the case on the Fedora dogfood host; check others with
the probe below, and expect it to be absent inside most containers). On first use the server probes this *with the real properties* —
including reading the new scope's `memory.max` back, because a manager without
the controller accepts `MemoryMax=` and silently ignores it. If the probe fails
the worker is spawned uncapped, one warning is logged
(`MemoryScope: per-worker memory cap unavailable — …`), and the probe is retried
after five minutes. `arb doctor` reports the same state.

## 2. `OOMPolicy=continue` on the service

`arb install service` now writes `OOMPolicy=continue` into the unit's `[Service]`
section. systemd's default, `stop`, stops the whole service when the kernel
OOM-kills *any* process in its cgroup; `continue` leaves the survivors running
(and if the server's own BEAM is the one killed, `Restart=on-failure` still
brings it back). It is the backstop for whatever still lives in the unit's
cgroup — the cap protects against workers, this protects against everything else.

### An already-installed unit is host config

Re-running `arb install service` rewrites the unit and picks the line up. If you
would rather not regenerate it, add a drop-in:

```sh
systemctl --user edit wardmast.service
```

```ini
[Service]
OOMPolicy=continue
```

then `systemctl --user daemon-reload`. (A system-wide install: drop `--user`.)
The change takes effect for the running service on its next restart; verify with

```sh
systemctl --user show wardmast.service -p OOMPolicy
```

## 3. Attributing an OOM to a task

Every spawn's scope unit name is recorded on the run, `worker_runs.cgroup_scopes`
(one entry per spawn, in order), and logged at spawn time:

```
Worker: task=bd-6zuoo6 run=… agent spawned in scope arb-run-bd-6zuoo6-1a2b3c4d.scope (MemoryMax=40%)
```

A kernel OOM line names the victim's cgroup (`task_memcg=…/arb-run-bd-6zuoo6-1a2b3c4d.scope`),
so:

```sh
journalctl -k --since '1 hour ago' | grep -i 'oom'          # → …/arb-run-<task>-<hex>.scope
sqlite3 ~/.wardmast/arbiter.sqlite3 \
  "select task_id, id, stop_category from worker_runs where cgroup_scopes like '%arb-run-<task>-<hex>%'"
```

Runs that predate the column, or ran with the cap off or unavailable, have a
NULL `cgroup_scopes`.

## 4. `arb doctor`

The **worker memory cap** check asks the server which systemd unit it runs in,
that unit's `OOMPolicy`, and whether the cap is in force. It warns when

- the unit has `OOMPolicy=stop` and workers are **not** capped (the incident
  configuration), or
- the unit has `OOMPolicy=stop` even though workers are capped, or
- workers are not capped even though `OOMPolicy=continue` is set.

A server that is not a systemd service (a shell-launched `mix phx.server`) has no
policy to judge and reports ok.

## Reproducing by hand

Without Wardmast, on any host that can run the scope:

```sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemd-run --user --scope --quiet --unit=arb-demo \
  -p MemoryMax=64M -p MemorySwapMax=0 -p OOMPolicy=kill \
  sh -c 'tail /dev/zero'; echo "exit=$?"            # exit=137
systemctl --user show arb-demo.scope -p Result,MemoryPeak,ActiveState
#   Result=oom-kill  MemoryPeak=67108864  ActiveState=failed
systemctl --user reset-failed arb-demo.scope
```

The end-to-end proof inside Wardmast is the opt-in `:live_systemd` test:

```sh
XDG_RUNTIME_DIR=/run/user/$(id -u) \
  mix test --include live_systemd test/integration/worker_memory_cap_test.exs
```

It starts a second worker beside the runaway one and asserts that only the
runaway is killed, that its run row is `failed` / `memory_cap_exceeded`, and that
the failed scope was cleared.

## On macOS: an optional RSS watchdog

macOS has no cgroups, so there is nothing for the kernel to enforce. Instead
(`Wardmast.Worker.MemoryWatchdog`, bd-d627b8) the server **polls**: every 5 s it
reads `ps -axo pgid=,rss=`, sums the RSS of every process in the worker's
process group (the agent and what it started, see `Wardmast.Worker.ProcessGroup`),
and when the sum is above the cap it kills the group. The run is recorded
exactly as on Linux — failed, stop category `memory_cap_exceeded` — with a reason
that names the watchdog and the highest RSS it sampled.

It is **opt-in** and uses the same setting as the Linux cap:
`WARDMAST_WORKER_MEMORY_MAX` (`12G`, `512M`, or a percentage of physical RAM
read from `sysctl hw.memsize`) or `config :wardmast, :worker_memory_max`. Unset,
`off`, `0`, `none`, `infinity` or an unparseable value means no watchdog; there
is no default cap on macOS, because this one is approximate. Linux hosts never
start it.

Best-effort means: memory can grow well past the cap between two polls, RSS
double-counts shared pages, a process that left the group (its own `setsid`) is
not counted, and a failed `ps` skips that sample. Treat the cap as a backstop
against a slow runaway, not a guarantee.

## Not covered

Spawns that are not agent sessions — `git`, `gh`, the doctor's probes, a
coordinator session's tmux scope (which already has its own
`systemd-run --user --scope`) — stay in the service cgroup, as before. That is
what `OOMPolicy=continue` is for.

## Cluster pods (bd-76727c, GitHub #1651)

Everything above is the **local** worker: a systemd scope capped by
`WARDMAST_WORKER_MEMORY_MAX`. A worker placed on a `cluster` node (k8s) is capped
by something else: the worker container's `resources.limits.memory`
(`worker.limits.memory` in the controller config, default `4Gi`), bounded above by
the namespace's `LimitRange` max (set at `arb node … install` time from the
`memory` parameter). `WARDMAST_WORKER_MEMORY_MAX` does not apply.

What counts against that one limit: the agent CLI (~0.3–1 GiB), every BEAM the
agent starts (compile, `mix test`, credo, dialyzer), a headless browser if the task
starts one, **and** (before bd-c22gf1) the pod's `/tmp`, a `medium: Memory` `emptyDir` whose
bytes were charged to the container. `/tmp` is now a plain disk `emptyDir`
(`tmp_size_limit`, 1Gi) and counts against the worker's `ephemeral-storage` limit
(`work_size_limit + tmp_size_limit`, 9Gi by default; request 4Gi) instead. The only
memory-backed volumes left are `run` (64Mi: the secret env file, which must never
touch disk) and any run-service `tmpfs` entries (256Mi each, services only).
`/dev/shm` is the runtime default, not a spec volume.

### What the 2026-11 kills were (bd-76727c)

All 11 kills between 11-19 and 11-24 ran on the `mesaana` cluster node
(`worker_runs.node_id`), including `bd-4j0nfe#review`, which was recorded as local.
They were 3/174 runs (11-19), 4/71 (11-20), 1/110 (11-21), 4/8 (11-24) — arbiter
had run there since late October with none, so the workload sits at the 4Gi line,
not past a cliff. The run rows carried no cap and no peak (`MemoryMax=the node's
memory cap`): the kubelet reports neither after the kill, and the worker did not
read the limit from the pod spec.

Measured on a 12-core host (anonymous memory above the run's baseline, cgroup
`memory.stat`, sampled each second; file cache excluded):

| workload | peak anon |
| --- | --- |
| cold `mix compile` (test env), 12 schedulers | 1.4 GiB |
| cold `mix compile`, `+S 64:64` (a many-core node's default) | 1.9 GiB |
| `mix test` on `apps/wardmast`, `ARB_TEST_MAX_CASES=1`, first 9.5 min | 1.8 GiB |
| same, `ARB_TEST_MAX_CASES=4`, first 6.5 min | 1.7 GiB |
| same, `ARB_TEST_MAX_CASES=16`, first 5 min | 2.0 GiB |

`$TMPDIR` for the run stayed at 18 MB. So one BEAM is ~2 GiB regardless of
`max_cases`; with the agent that is ~2.5 GiB of a 4Gi limit. **Not observed
directly** (the pods are gone and the kill leaves no peak): the likely trigger is a
second heavy process overlapping that one (a compile while a test run is still
going, credo or dialyzer beside a suite, a headless browser), which is why no
per-process cap fixes it: the limit is shared. The in-pod biggest-process is not
cheap to capture (the API exposes no `memory.peak` or process list after a kill);
the failure message therefore names the container's limit, and the first thing to
check is the run transcript's last two commands.

### What changed

* The kill is attributed: `PodState` reads the worker container's limit from the
  pod spec, the exit report carries it (`memory_limit`), and the run's failure
  reason reads "the worker's container hit its memory limit (4Gi) on its node".
* Worker test default concurrency (`scripts/test_max_cases.exs`) is capped at 4,
  with a guard in `apps/wardmast_release_env/test/test_max_cases_test.exs`. This is
  **hygiene, not the fix**: the table above shows the BEAM's peak is nearly flat in
  `max_cases`, so the cap does not lower the peak that caused the kills. What bounds
  the default: `System.schedulers_online/0` defaults to the CPUs the BEAM may use,
  i.e. its CPU affinity and, on OTP 23+, the cgroup `cpu_quota` (a 2-CPU pod gets 2
  schedulers, so `max_cases` 2); the hard cap of 4 bounds it on a many-core host.
* The failure remediation is node-kind aware: a cluster pod (its exit carries the
  pod's limit) is pointed at the LimitRange and controller config; a machine node
  at its `podman run --memory` share (`remote_worker_memory_share`). Fallback: the
  kind is inferred from whether the exit carries the pod's limit, so a cluster pod
  whose spec has no worker memory limit (a LimitRange without a default) would get
  the podman wording; `worker.limits.memory` defaults to 4Gi, so this is not expected.

**Still to do, and not code:** raise the cluster limit (below) and/or serialise
heavy BEAMs. That is the operator's call and is what actually addresses the kills.

### Raising the limit (operator)

The limit is cluster config, and a pod whose limit exceeds the `LimitRange` max is
refused at admission, so raise the two together, LimitRange first:

1. Re-render the install manifest with a larger `memory` (e.g. `6Gi`) and apply it,
   so the namespace's `LimitRange` max and `ResourceQuota` grow with it.
2. Set `worker.limits.memory` (and `requests.memory`, ≤ half the limit under the
   `maxLimitRequestRatio`) in the controller config to the same figure and restart
   the controller.

By the figures above 6Gi holds two BEAMs plus the agent; size the quota for `max_concurrent × 6Gi`.

# Worker process groups

Every local agent spawn (the agent CLI itself, or the `podman` client of a
container run) is the leader of its own OS process group, and Wardmast kills
that group as a whole:

- **when the agent exits**: whatever it backgrounded (a `mix test`, a dev
  server), including processes that were reparented to init and that no
  parent-child walk can find any more;
- **when the worker is torn down**: a failure, `arb worker stop`, or a server
  shutdown;
- **at the next boot**, for runs a crash left live: only while the process the
  run recorded is still the same process (see [Boot sweep](#boot-sweep)).

On Linux with systemd this sits next to the per-worker memory scope
([worker-memory-cap.md](worker-memory-cap.md)), which kills the scope's
processes with the service. On macOS, and on any host without a user manager,
the process group is the only containment there is (bd-568ib9, MAC P2-1).

## The group

Erlang starts every port program in its own session: `erl_child_setup` calls
`setsid()` before it execs the program, on Linux and macOS alike. So an agent's
pid is also its process-group id, and everything it starts stays in that group
unless it leaves on purpose (`setsid`, `setpgid`). The server's own process
group never contains a worker, so a supervisor's group kill on stop (launchd's,
with or without `AbandonProcessGroup`) does not reach workers either way: the
server kills them itself, on shutdown.

## The warden

Each agent is launched through a short `perl` program that `exec`s the agent in
place (same pid, arguments, environment and exit status) after forking one
extra process into the group, the **warden**:

```
$ ps -o pid,pgid,args -p "$(pgrep -d, -g 4242)"
  PID  PGID ARGS
 4242  4242 claude --print ...
 4243  4242 wardmast-group-warden 4242
```

(`pgrep -l` shows the warden's short name, `wardmast-group-` on Linux.)

The warden holds no file descriptors of the agent's (its stdio is `/dev/null`),
checks once a second whether the agent is still alive and, once it is not,
SIGKILLs the whole group, itself included. That way:

- after a server crash, the agent usually dies on its next write to its closed
  output pipe, and the warden then kills what it left behind without waiting for
  the server to come back;
- a group outlives its agent only for as long as the warden takes to notice, so
  the boot sweep only has to deal with agents that are still running;
- spawns the server does not reap itself (the doctor's spawn canary, CLI replays)
  cannot leak a backgrounded child either.

`perl` ships with macOS and with practically every Linux; without it agents are
launched directly. To launch them directly anyway, set

```
WARDMAST_WORKER_GROUP_WARDEN=off
```

in the server's environment (`~/.wardmast/wardmast.env`) and restart. The group
is still recorded and killed by the server after the agent exits, on teardown
and at boot; only what the warden adds is lost.

## What is recorded

Each run records its latest local spawn in `worker_runs`:

| Column | What |
|---|---|
| `os_pid` | the agent's pid (the port's OS process) |
| `os_pgid` | the process group it leads (its own pid); NULL if it was not leading one |
| `os_started_at` | when that process started, from `ps -o lstart=` (to the second, UTC); NULL if it could not be read |

All three are NULL for a run on a node and for runs from before this change.
To see what is still running for a run: `ps -o pid,pgid,args -p "$(pgrep -d, -g <os_pgid>)"`.

## Boot sweep

On boot, before orphaned live runs are marked `interrupted` ("server
restarted") and before anything is resumed into their worktrees, the primary
instance looks at each such run that recorded a group. It kills the group only
when the process at `os_pid` is still alive, still leads its group, and started
within 5 seconds of `os_started_at` (Linux derives the start time from the boot
time, which can move by a second or so). A pid the OS has given to another
process since, after a reboot for instance, fails that check and is left alone.
The server log says what it did:

```
[warning] ProcessGroup: killed orphaned worker process group 4242 (task bd-xxxxxx, run <uuid>)
[info] ProcessGroup: pid 4242 (task bd-xxxxxx, run <uuid>) now belongs to another process; left alone
```

## Limits

- A process that leaves the group on purpose (a daemon calling `setsid`) is out
  of reach of a group kill. While its parent is alive, teardown's process-tree
  walk still finds it.
- Only a run's latest spawn is recorded. An earlier spawn of the same run that
  is still running when the server crashes is left to its warden.
- If the warden itself is killed by hand while its agent's leftovers are
  running, and the agent then exits during a server outage, nothing kills
  those leftovers.
- A development server stopped with Ctrl-C and `(a)bort` never runs its
  shutdown: its agents run on until they exit (their wardens then clean up) or
  the next boot sweeps them.

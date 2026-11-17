defmodule Wardmast.Worker.ProcessGroup do
  # Seconds a recorded start time may differ from what `ps` reports now. Linux
  # derives `lstart` from the boot time, which moves by a second or so as the
  # clock is adjusted; a pid cannot come round again within seconds.
  @start_tolerance_s 5

  @moduledoc """
  A worker's agent as one OS process group: recorded at spawn, killed as a
  whole after it exits and on shutdown, and swept at boot after a crash
  (bd-568ib9, MAC P2-1; design bd-6tif6q §4).

  ## The group

  Every Erlang port child already leads its own session and process group:
  `erl_child_setup` calls `setsid()` between fork and exec on every Unix (the
  `USE_SETPGRP*` alternatives are never defined in OTP's tree). So the agent's
  OS pid is its process-group id too, and everything it starts stays in that
  group unless it leaves on purpose (`setsid`, `setpgid`). One `kill(-pgid)`
  reaches all of it, including what the agent backgrounded and what was
  reparented to init when its parent exited, which the `pgrep -P` walk of
  `Wardmast.Worker.OsProcess.kill_tree/1` can no longer see. The server's own
  group is never involved.

  ## The launcher (`wrap/2`)

  A local agent spawn is launched through a short `perl` program (perl is in
  the macOS base system and on practically every Linux) that `exec`s the agent
  in place, so its pid, argv, environment and exit status are unchanged, after:

    1. making sure the process leads its own session (`setsid()` unless it
       already does; under ERTS it always does, so this only guards the
       invariant against another launcher), and
    2. forking the group's **warden**: a child that stays in the group with its
       stdio on `/dev/null` (it never holds the port open), checks once a second
       whether the agent is still alive and, once it is not, SIGKILLs the whole
       group, itself included.

  The warden makes the group clean itself up, and makes the boot sweep sound:

    * after a server crash the agent usually dies on its next write to the
      closed stdout pipe, and the warden then kills what it left behind without
      waiting for the server to come back;
    * a group outlives its leader only for as long as the warden takes to
      notice, so the boot sweep can require the *leader* to be alive and to be
      the recorded process (see below), and a dead leader means nothing is
      left to leak (unless the warden itself was killed);
    * a caller of `Wardmast.Worker.ClaudeSession.open_scoped_port/2` that never
      reaps (the doctor's spawn canary, the loop's CLI replay) cannot leak a
      backgrounded child either.

  `WARDMAST_WORKER_GROUP_WARDEN=off` (or `config :wardmast, :worker_group_warden,
  false`) launches agents directly again. Their groups are still recorded and
  killed by the server; only what the warden adds is lost. Without `perl` the
  spawn is launched directly.

  ## What is recorded (`describe/2`)

  The agent's pid, its process group and its start time, read with `ps -o
  pgid=,lstart=` in the C locale and UTC, and stored on the run
  (`worker_runs.os_pid`, `os_pgid`, `os_started_at`).

  ## Killing

    * `kill/2`: the post-exit reap and the shutdown kill. The server has just
      seen the group (its port is open or has just closed), and a pgid cannot be
      reused while any member of the group is alive, so the signal reaches the
      run's own processes or nothing.
    * `sweep/2`: the boot sweep, for runs a crash left behind. Time has passed,
      the host may even have rebooted, so a group is killed only when its leader
      is still alive and is the recorded process: the same pid, still leading
      the group, and started within #{@start_tolerance_s} s of the recorded start time. A
      pid reused by anything else since fails that check and is left alone.

  Neither ever signals a target that cannot be a worker's group: a pgid of 1 or
  less, or the server's own pid or process group.

  ## Limits

  A process that leaves the group on purpose (a daemon calling `setsid`) is out
  of reach of a group kill; the tree walk still catches it while it has a
  parent in the tree. Only a run's latest spawn is recorded; an earlier one
  still running when the server crashes is left to its warden.
  """

  require Logger

  @warden_interval_s 1
  @describe_retries 2
  @gone_attempts 25
  @off ~w(off false 0 no disabled)
  @own_pgid_key {__MODULE__, :own_pgid}

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
          |> Enum.with_index(1)
          |> Map.new()

  @typedoc """
  A recorded process group. `pgid` is nil when the agent did not lead its own
  group (it is then never group-killed); `started_at` is nil when `ps` could
  not say (the boot sweep then never acts on it). Callers may carry their own
  keys along (the Reconciler adds `run_id` and `task_id`).
  """
  @type t :: %{
          required(:pid) => pos_integer(),
          required(:pgid) => pos_integer() | nil,
          required(:started_at) => DateTime.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Launch `port_args` (`%{exec:, argv:, ...}`) through the warden launcher
  described in the moduledoc. Returns `port_args` untouched when the launcher
  is disabled, `perl` cannot be found, or `exec` is not an executable file (so
  `Port.open/2` refuses a missing agent exactly as before).

  Options (test seams): `:enabled`, `:perl` (`nil` = none), `:warden_interval_s`.
  """
  @spec wrap(map(), keyword()) :: map()
  def wrap(%{exec: exec, argv: [_argv0 | rest]} = port_args, opts \\ []) do
    with true <- Keyword.get_lazy(opts, :enabled, &warden_enabled?/0),
         perl when is_binary(perl) <- Keyword.get_lazy(opts, :perl, &perl_path/0),
         true <- executable?(exec) do
      interval = Keyword.get(opts, :warden_interval_s, @warden_interval_s)
      %{port_args | exec: perl, argv: [perl, "-e", launcher(interval), "--", exec | rest]}
    else
      _ -> port_args
    end
  end

  @doc """
  Whether agents are launched through the warden launcher.
  `WARDMAST_WORKER_GROUP_WARDEN` (`off`/`false`/`0`/`no`/`disabled` turn it off)
  beats `config :wardmast, :worker_group_warden`; on by default.
  """
  @spec warden_enabled?(keyword()) :: boolean()
  def warden_enabled?(opts \\ []) do
    env =
      Keyword.get_lazy(opts, :env, fn -> Wardmast.Env.get("WARDMAST_WORKER_GROUP_WARDEN") end)

    config =
      Keyword.get_lazy(opts, :config, fn ->
        Application.get_env(:wardmast, :worker_group_warden)
      end)

    case env && String.trim(env) do
      blank when blank in [nil, ""] -> config != false
      value -> String.downcase(value) not in @off
    end
  end

  @doc "The `perl` the launcher runs under: the system one first, else the first on `PATH`."
  @spec perl_path() :: String.t() | nil
  def perl_path do
    if executable?("/usr/bin/perl"), do: "/usr/bin/perl", else: System.find_executable("perl")
  end

  @doc """
  The process group of the port child `os_pid`, to record on its run.

  `pgid` is `os_pid` when `ps` shows the process leading its own group (or when
  it is already gone: a port child always led its own group, so the post-exit
  reap may still signal it), and nil when it is in another process's group.
  `started_at` is nil when `ps` cannot say. Never raises.

  Options (test seams): `:ps` (`fn os_pid -> {output, exit_status} end`),
  `:retries`.
  """
  @spec describe(integer(), keyword()) :: t()
  def describe(os_pid, opts \\ []) when is_integer(os_pid) do
    ps = Keyword.get(opts, :ps, &ps/1)
    do_describe(os_pid, ps, Keyword.get(opts, :retries, @describe_retries))
  end

  # A port child leads its group from just after fork; the retry only covers a
  # `ps` that lands in between.
  defp do_describe(os_pid, ps, retries) do
    case read(os_pid, ps) do
      {:ok, ^os_pid, started_at} ->
        %{pid: os_pid, pgid: os_pid, started_at: started_at}

      {:ok, _other, _started_at} when retries > 0 ->
        Process.sleep(10)
        do_describe(os_pid, ps, retries - 1)

      {:ok, _other, started_at} ->
        %{pid: os_pid, pgid: nil, started_at: started_at}

      :error ->
        %{pid: os_pid, pgid: os_pid, started_at: nil}
    end
  end

  @doc """
  SIGKILL a run's process group now (the post-exit reap, the shutdown kill),
  then wait briefly for it to disappear. Takes a recorded group or a pgid.

  Returns `:ok`, `:gone` (no such group, or none recorded), `{:error,
  :survived}` (signalled, but members were still there after the wait) or
  `{:error, :unsafe_target}` (a pgid that cannot be a worker's; nothing is
  sent). Only for a group the server has just seen: a boot-time caller must use
  `sweep/2`. Never raises.

  Options (test seam): `:kill` (`fn args -> {output, exit_status} end`).
  """
  @spec kill(t() | integer() | nil, keyword()) :: :ok | :gone | {:error, term()}
  def kill(group, opts \\ [])
  def kill(nil, _opts), do: :gone
  def kill(%{pgid: pgid}, opts), do: kill(pgid, opts)

  def kill(pgid, opts) when is_integer(pgid) do
    if safe_target?(pgid) do
      signal_group(pgid, Keyword.get(opts, :kill, &run_kill/1))
    else
      {:error, :unsafe_target}
    end
  end

  @doc """
  The boot sweep: kill each recorded group whose leader is still alive and is
  still the process that was recorded (same pid, leading the same group, started
  within #{@start_tolerance_s} s of `started_at`). A group recorded without a pgid or a start
  time, whose leader is gone, or whose pid now belongs to another process is
  left alone. Each kill is logged. Returns the groups it killed.

  Options (test seams): `:ps`, `:kill`, `:tolerance_s`.
  """
  @spec sweep([t()], keyword()) :: [t()]
  def sweep(groups, opts \\ []) do
    ps = Keyword.get(opts, :ps, &ps/1)
    tolerance = Keyword.get(opts, :tolerance_s, @start_tolerance_s)

    for group <- groups, reduce: [] do
      acc ->
        case sweep_one(group, ps, tolerance, opts) do
          :killed -> [group | acc]
          _ -> acc
        end
    end
    |> Enum.reverse()
  end

  defp sweep_one(group, ps, tolerance, opts) do
    with :ok <- verifiable(group),
         :ours <- identify(group, ps, tolerance),
         :ok <- kill(group.pgid, opts) do
      Logger.warning(
        "ProcessGroup: killed orphaned worker process group #{group.pgid}#{owner(group)}"
      )

      :killed
    else
      {:skip, :reused} ->
        Logger.info(
          "ProcessGroup: pid #{group.pid}#{owner(group)} now belongs to another process; " <>
            "left alone"
        )

        :skipped

      {:error, :survived} ->
        Logger.warning(
          "ProcessGroup: orphaned worker process group #{group.pgid}#{owner(group)} " <>
            "still had members after SIGKILL"
        )

        :killed

      {:error, reason} ->
        Logger.warning(
          "ProcessGroup: did not kill process group #{inspect(group.pgid)}#{owner(group)}: " <>
            inspect(reason)
        )

        :skipped

      _ ->
        :skipped
    end
  end

  defp verifiable(%{pid: pid, pgid: pid, started_at: %DateTime{}}) when is_integer(pid),
    do: :ok

  defp verifiable(_group), do: {:skip, :unverifiable}

  defp identify(%{pid: pid, started_at: recorded}, ps, tolerance) do
    case read(pid, ps) do
      :error ->
        {:skip, :gone}

      {:ok, ^pid, %DateTime{} = started_at} ->
        if abs(DateTime.diff(started_at, recorded)) <= tolerance,
          do: :ours,
          else: {:skip, :reused}

      {:ok, ^pid, nil} ->
        {:skip, :unverifiable}

      {:ok, _other_pgid, _started_at} ->
        {:skip, :reused}
    end
  end

  defp owner(%{task_id: task_id, run_id: run_id}), do: " (task #{task_id}, run #{run_id})"
  defp owner(_group), do: ""

  # ---- internals ---------------------------------------------------------------

  # `$leader` is the agent's pid: the launcher execs the agent in place.
  defp launcher(interval) do
    """
    my $iv = #{interval};
    my $leader = $$;
    if (getpgrp() != $leader) { require POSIX; POSIX::setsid(); }
    if (getpgrp() == $leader) {
      my $pid = fork();
      if (defined $pid && $pid == 0) {
        open(STDIN, '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        $0 = "wardmast-group-warden $leader";
        select(undef, undef, undef, $iv) while kill(0, $leader);
        kill('-KILL', $leader);
        exit(0);
      }
    }
    exec { $ARGV[0] } @ARGV or die "wardmast: exec $ARGV[0]: $!\\n";
    """
  end

  defp executable?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp executable?(_path), do: false

  defp signal_group(pgid, kill_fun) do
    case kill_fun.(["-KILL", "--", "-#{pgid}"]) do
      {_, 0} -> if gone?(pgid, kill_fun), do: :ok, else: {:error, :survived}
      _ -> :gone
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # SIGKILL is prompt; members only linger as zombies until reaped. Bounded so a
  # wedged one cannot hold up a teardown.
  defp gone?(pgid, kill_fun) do
    Enum.reduce_while(1..@gone_attempts, false, fn _attempt, _acc ->
      case kill_fun.(["-0", "--", "-#{pgid}"]) do
        {_, 0} ->
          Process.sleep(20)
          {:cont, false}

        _ ->
          {:halt, true}
      end
    end)
  end

  defp safe_target?(pgid), do: pgid > 1 and pgid not in own_ids()

  # The server's own pid and process group. Its group cannot change while it
  # runs, so it is read once.
  defp own_ids do
    self_pid = String.to_integer(System.pid())

    case :persistent_term.get(@own_pgid_key, :unknown) do
      :unknown ->
        pgid =
          case read(self_pid, &ps/1) do
            {:ok, pgid, _} -> pgid
            :error -> nil
          end

        :persistent_term.put(@own_pgid_key, pgid)
        Enum.reject([self_pid, pgid], &is_nil/1)

      pgid ->
        Enum.reject([self_pid, pgid], &is_nil/1)
    end
  end

  defp read(os_pid, ps) do
    case ps.(os_pid) do
      {out, 0} -> parse(out)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # `<pgid> <Dow> <Mon> <day> <HH:MM:SS> <year>`; the first line that starts
  # with a number (a `ps` warning on stderr cannot be mistaken for it).
  defp parse(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [pgid | lstart] ->
          case Integer.parse(pgid) do
            {pgid, ""} -> {:ok, pgid, parse_lstart(lstart)}
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp parse_lstart([_dow, mon, day, time, year]) do
    with {:ok, month} <- Map.fetch(@months, mon),
         {day, ""} <- Integer.parse(day),
         {year, ""} <- Integer.parse(year),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp parse_lstart(_fields), do: nil

  # `ps`/`kill` are spelled out literally (the release-env guard's rule 1).
  defp ps(os_pid) do
    System.cmd("ps", ["-o", "pgid=,lstart=", "-p", Integer.to_string(os_pid)],
      stderr_to_stdout: true,
      env: [{"LC_ALL", "C"}, {"TZ", "UTC0"}]
    )
  end

  defp run_kill(args), do: System.cmd("kill", args, stderr_to_stdout: true)
end

defmodule Wardmast.NodeAgent.Runs do
  @moduledoc """
  The agent's run table and its API for `Wardmast.NodeAgent.Connection`
  (`docs/design/remote-workers.md` §12): one `Wardmast.NodeAgent.Run` per
  `assign`, under a `DynamicSupervisor`, found by run id in a `Registry`.

  `assign/2` validates the spec first (`Wardmast.NodeAgent.RunSpec`); a refused
  spec starts nothing. Everything else is addressed by run id and is idempotent:
  an unknown id is `{:error, :not_found}`.
  """

  alias Wardmast.NodeAgent.{Run, RunSpec}

  @registry Wardmast.NodeAgent.RunRegistry
  @supervisor Wardmast.NodeAgent.RunSupervisor

  @doc "The children the agent supervisor starts for the run table."
  @spec child_specs() :: [{module(), keyword()}]
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      Wardmast.NodeAgent.Exec,
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  @doc """
  Start run `spec` (the decoded `assign` payload's `"spec"`). `opts` are the
  agent's run options (`:config`, `:podman`, `:runner`, `:runtime_dir`, …).
  Returns `{:ok, run_id}`, `{:error, {:refused, reason}}` for a spec the agent
  will not build, or `{:error, :already_running}`.
  """
  @spec assign(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def assign(spec, opts) do
    with {:ok, %RunSpec{} = validated} <- RunSpec.validate(spec),
         :ok <- machine_deliverable(validated) do
      case DynamicSupervisor.start_child(@supervisor, {Run, {validated, opts}}) do
        {:ok, _pid} -> {:ok, validated.run}
        {:error, {:already_started, _pid}} -> {:error, :already_running}
        {:error, reason} -> {:error, {:start_failed, reason}}
      end
    end
  end

  # bd-b2t0kw: `secret_files` reach a cluster pod's memory volume through `/boot`; a
  # machine node has no layout for them yet, so it refuses the run rather than start it
  # without its credential. (Placement sends agy, their only user, to `caps.agy` nodes.)
  defp machine_deliverable(%RunSpec{secret_files: files}) when map_size(files) > 0,
    do: {:error, {:refused, {:unsupported, "secret_files"}}}

  defp machine_deliverable(%RunSpec{}), do: :ok

  @doc "Every run's `Run.info/1`: what `hello` and `hb` report."
  @spec inventory() :: [map()]
  def inventory do
    for run <- run_ids(), info = Run.info(run), not is_nil(info), do: info
  catch
    :exit, _ -> []
  end

  @doc "The ids of the runs the table holds."
  @spec run_ids() :: [String.t()]
  def run_ids do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc """
  The channel is up: every run rewinds to its last ack and resends. Runs in `skip`
  (the ones the primary does not know, being quiesced) are left alone.
  """
  @spec attach_all([String.t()]) :: :ok
  def attach_all(skip \\ []), do: each(&Run.attach/1, skip)

  @doc "The channel went away."
  @spec detach_all() :: :ok
  def detach_all, do: each(&Run.detach/1)

  @doc "The self-fence: stop every container (§10.1); output and transcripts stay."
  @spec fence_all() :: :ok
  def fence_all, do: each(&Run.cancel(&1, "fenced"))

  defp each(fun, skip \\ []) do
    Enum.each(run_ids() -- skip, fun)
    :ok
  end
end

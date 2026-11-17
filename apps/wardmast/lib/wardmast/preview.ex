defmodule Wardmast.Preview do
  @moduledoc """
  App previews: run a ticket's checkout as a live app, on a port nothing else
  holds, to see what a worktree is doing. Docs: `docs/app-preview.md`.

  `start/2` resolves the repo's `worker.repos.<repo>.preview` config
  (`Wardmast.Preview.Config`), leases a port (`Wardmast.Preview.Leases`: a
  persisted table, unique per port, drawn from a dedicated range that can never
  include the server's own port or a worker dev-server port), picks a checkout
  that never disturbs a live worker's (`Wardmast.Preview.Checkout`) and starts a
  supervised `Wardmast.Preview.Runner`, which runs the optional `setup`, the
  `command` (in its own process group), probes `ready_path` and reports the URL.
  It returns as soon as the runner is up (`wait: true` blocks until the preview
  is ready or failed); progress is on the lease row and the `topic/0` PubSub
  topic.

  Previews bind to `127.0.0.1` (`host/0`). They stop on request, when the ticket
  closes or merges, when the checkout they run in is removed, and after the
  repo's `idle_ttl_seconds` without being touched (`sweep/0`, driven by
  `Wardmast.Preview.Sweeper`). "Touched" means started, shown, or its log read
  through Wardmast — starting again extends it.
  """

  alias Wardmast.Config.Paths
  alias Wardmast.Preview.Checkout
  alias Wardmast.Preview.Config
  alias Wardmast.Preview.Lease
  alias Wardmast.Preview.Leases
  alias Wardmast.Preview.Runner
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.RepoConfig
  alias Wardmast.Tasks.Workspace

  @topic "previews"
  @host "127.0.0.1"
  @default_log_lines 200

  @doc "The PubSub topic that carries `:previews_changed` on every state change."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The address previews are probed and linked on."
  @spec host() :: String.t()
  def host, do: @host

  @doc "The URL a preview on `port` is reachable at."
  @spec url(non_neg_integer()) :: String.t()
  def url(port), do: "http://#{@host}:#{port}/"

  @doc false
  def broadcast do
    Phoenix.PubSub.broadcast(Wardmast.PubSub, @topic, :previews_changed)
  end

  @doc "The directory holding a preview's log, setup marker and checkout."
  @spec dir(String.t(), String.t()) :: String.t()
  def dir(repo, task_id), do: Path.join([Paths.preview_root(), safe(repo), safe(task_id)])

  defp safe(s), do: String.replace(s, ~r/[^A-Za-z0-9._-]/, "_")

  @doc "The log file path of a preview."
  @spec log_path(String.t(), String.t()) :: String.t()
  def log_path(repo, task_id), do: Path.join(dir(repo, task_id), "preview.log")

  # ---- start ---------------------------------------------------------------

  @doc """
  Start a preview of `task_id`. Options: `:repo` (default the ticket's repo),
  `:wait` (block until ready/failed, default false), `:timeout` (ms bound for
  `:wait`).

  Starting a preview that is already starting or running only touches it and
  returns the existing row.
  """
  @spec start(String.t(), keyword()) :: {:ok, Lease.t()} | {:error, term()}
  def start(task_id, opts \\ []) when is_binary(task_id) do
    with {:ok, issue} <- fetch_issue(task_id),
         {:ok, repo} <- pick_repo(issue, opts),
         {:ok, workspace} <- fetch_workspace(issue),
         {:ok, cfg} <- resolve_config(workspace, repo),
         {:ok, lease} <- lease_and_launch(issue, workspace, repo, cfg) do
      if Keyword.get(opts, :wait, false),
        do: await(lease.repo, lease.task_id, Keyword.get(opts, :timeout, :default)),
        else: {:ok, lease}
    end
  end

  defp lease_and_launch(issue, workspace, repo, cfg) do
    case lease(issue, workspace, repo, cfg) do
      {:ok, lease} -> launch(issue, workspace, repo, cfg, lease)
      {:existing, row} -> {:ok, row}
      {:error, _} = error -> error
    end
  end

  defp fetch_issue(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = issue} -> {:ok, issue}
      _ -> {:error, :ticket_not_found}
    end
  end

  defp pick_repo(issue, opts) do
    case Keyword.get(opts, :repo) || issue.repo do
      repo when is_binary(repo) and repo != "" -> {:ok, repo}
      _ -> {:error, :no_repo}
    end
  end

  defp fetch_workspace(%Issue{workspace_id: ws_id}) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> {:error, :workspace_not_found}
    end
  end

  defp resolve_config(workspace, repo) do
    case Config.resolve(workspace, repo) do
      {:ok, cfg} -> {:ok, cfg}
      {:error, :not_configured} -> {:error, {:not_configured, repo}}
      {:error, {:invalid, errors}} -> {:error, {:invalid_config, errors}}
    end
  end

  defp lease(issue, workspace, repo, cfg) do
    attrs = %{
      repo: repo,
      task_id: issue.id,
      workspace_id: workspace.id,
      log_path: log_path(repo, issue.id)
    }

    case Leases.acquire(attrs, cfg.port_range) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, {:already_leased, existing}} ->
        if Runner.whereis(repo, issue.id) do
          _ = Leases.update(existing, %{touched_at: DateTime.utc_now()})
          {:existing, Leases.get(repo, issue.id)}
        else
          orphaned(existing)
          lease(issue, workspace, repo, cfg)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp launch(issue, workspace, repo, cfg, lease) do
    dir = dir(repo, issue.id)

    result =
      with {:ok, repo_path} <- repo_path(workspace, repo),
           {:ok, checkout} <- Checkout.prepare(issue, repo_path, dir),
           {:ok, lease} <-
             Leases.update(lease, %{
               checkout_path: checkout.path,
               checkout_kind: checkout.kind,
               checkout_note: checkout.note
             }),
           _ = File.rm(lease.log_path),
           {:ok, _pid} <-
             DynamicSupervisor.start_child(
               Wardmast.Preview.Supervisor,
               {Runner,
                %{
                  repo: repo,
                  task_id: issue.id,
                  lease_id: lease.id,
                  config: cfg,
                  checkout: checkout.path,
                  port: lease.port,
                  state_dir: dir,
                  log_path: lease.log_path
                }}
             ) do
        {:ok, lease}
      end

    case result do
      {:ok, lease} ->
        broadcast()
        {:ok, lease}

      {:error, reason} ->
        Leases.delete(lease)
        broadcast()
        {:error, reason}
    end
  end

  defp repo_path(%Workspace{config: config}, repo) do
    path =
      RepoConfig.find_path((config || %{})["repo_paths"], repo) ||
        :wardmast
        |> Application.get_env(:repo_paths, %{})
        |> Map.get(repo)
        |> RepoConfig.repo_path_from_config()

    if path && File.dir?(path), do: {:ok, path}, else: {:error, {:no_repo_path, repo}}
  end

  defp orphaned(%Lease{} = lease) do
    {:ok, lease} = Leases.update(lease, %{status: "failed", error: "the preview process is gone"})
    {:ok, _} = Leases.release(lease)
    :ok
  end

  @doc """
  Wait until the preview is no longer `"starting"` (running or failed), or
  `timeout` ms pass (default: the config's `ready_timeout` plus a minute for
  setup and checkout). Returns the row either way.
  """
  @spec await(String.t(), String.t(), timeout() | :default) ::
          {:ok, Lease.t()} | {:error, :not_found}
  def await(repo, task_id, timeout \\ :default) do
    timeout = if timeout == :default, do: 10 * 60_000, else: timeout
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(repo, task_id, deadline)
  end

  defp do_await(repo, task_id, deadline) do
    case Leases.get(repo, task_id) do
      nil ->
        {:error, :not_found}

      %Lease{status: "starting"} = row ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:ok, row}
        else
          Process.sleep(200)
          do_await(repo, task_id, deadline)
        end

      row ->
        {:ok, row}
    end
  end

  # ---- stop / read ---------------------------------------------------------

  @doc """
  Stop `task_id`'s preview(s): kill the process group, release the port, drop
  the row. `repo:` narrows to one repo. `{:error, :not_found}` when none.
  """
  @spec stop(String.t(), keyword()) :: {:ok, [Lease.t()]} | {:error, :not_found}
  def stop(task_id, opts \\ []) do
    reason = Keyword.get(opts, :reason, "stopped")

    case rows(task_id, opts) do
      [] ->
        {:error, :not_found}

      rows ->
        Enum.each(rows, &stop_row(&1, reason))
        broadcast()
        {:ok, rows}
    end
  end

  @doc "Stop every preview of `task_id` (all repos); `:ok` also when none."
  @spec stop_for_task(String.t()) :: :ok
  def stop_for_task(task_id) when is_binary(task_id) do
    _ = stop(task_id, reason: "the ticket closed")
    :ok
  end

  defp stop_row(%Lease{} = row, reason) do
    if Runner.whereis(row.repo, row.task_id) do
      Runner.stop(row.repo, row.task_id, reason)
    else
      Leases.delete(row)
    end
  end

  defp rows(task_id, opts) do
    case Keyword.get(opts, :repo) do
      nil -> Enum.filter(Leases.list(), &(&1.task_id == task_id))
      repo -> List.wrap(Leases.get(repo, task_id))
    end
  end

  @doc "Every preview row (`:workspace_id` filters)."
  @spec list(keyword()) :: [Lease.t()]
  def list(opts \\ []) do
    case Keyword.get(opts, :workspace_id) do
      nil -> Leases.list()
      ws -> Enum.filter(Leases.list(), &(&1.workspace_id == ws))
    end
  end

  @doc "The preview of `task_id` (`:repo` narrows), touching it; nil when none."
  @spec get(String.t(), keyword()) :: Lease.t() | nil
  def get(task_id, opts \\ []) do
    case rows(task_id, opts) do
      [row | _] ->
        _ = Leases.update(row, %{touched_at: DateTime.utc_now()})
        Leases.get(row.repo, row.task_id)

      [] ->
        nil
    end
  end

  @doc """
  A preview's log. Options: `:lines` (the last N, default #{@default_log_lines})
  or `:offset` (everything from that byte, for following). Returns
  `%{content, offset}` — pass `offset` back to read on. Readable after a stop or
  a failure; `{:error, :not_found}` when there is no log at all.
  """
  @spec logs(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def logs(task_id, opts \\ []) do
    row = rows(task_id, opts) |> List.first()
    repo = (row && row.repo) || Keyword.get(opts, :repo) || repo_of(task_id)

    with true <- is_binary(repo),
         path = (row && row.log_path) || log_path(repo, task_id),
         {:ok, %{size: size}} <- File.stat(path) do
      if row, do: Leases.update(row, %{touched_at: DateTime.utc_now()})
      {:ok, %{content: read_log(path, size, opts), offset: size, path: path}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp repo_of(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{repo: repo}} -> repo
      _ -> nil
    end
  end

  defp read_log(path, size, opts) do
    case Keyword.get(opts, :offset) do
      offset when is_integer(offset) and offset >= 0 ->
        if offset >= size, do: "", else: read_range(path, offset, size - offset)

      _ ->
        path |> File.read!() |> tail(Keyword.get(opts, :lines, @default_log_lines))
    end
  end

  defp read_range(path, offset, len) do
    File.open!(path, [:read, :binary], fn io ->
      {:ok, data} = :file.pread(io, offset, len)
      data
    end)
  end

  defp tail(content, n) do
    content |> String.split("\n") |> Enum.take(-(n + 1)) |> Enum.join("\n")
  end

  @doc """
  A caller-facing `{kind, message}` for an error `start/2`, `stop/2` and friends
  return, in the vocabulary REST (`FallbackController`) and MCP share.
  """
  @spec error(term()) :: {atom(), String.t()}
  def error(:ticket_not_found), do: {:not_found, "ticket not found"}
  def error(:workspace_not_found), do: {:not_found, "the ticket's workspace was not found"}
  def error(:not_found), do: {:not_found, "no preview for that ticket"}

  def error(:no_repo),
    do: {:invalid_request, "the ticket has no repo; pass `repo`"}

  def error({:not_configured, repo}) do
    {:invalid_request,
     "repo #{repo} has no preview configured: set worker.repos.#{repo}.preview.command " <>
       "(docs/app-preview.md)"}
  end

  def error({:invalid_config, errors}),
    do: {:invalid, "preview config is invalid: " <> Enum.join(errors, "; ")}

  def error({:no_repo_path, repo}),
    do: {:invalid_request, "repo #{repo} has no checkout path configured in repo_paths"}

  def error(:no_repo_path), do: {:invalid_request, "the repo has no checkout path configured"}

  def error({:no_checkout, branch}) do
    {:not_found,
     "no checkout to preview: the ticket has none on this machine and branch #{branch} " <>
       "is not pushed to origin"}
  end

  def error(:range_exhausted),
    do:
      {:conflict, "every port in the preview range is in use; stop a preview or widen port_range"}

  def error(:range_overlaps_worker_ports),
    do: {:invalid, "the preview port_range overlaps the worker dev-server range 20000-29999"}

  def error({:git, msg}), do: {:server_error, "git failed preparing the checkout: " <> msg}
  def error(other), do: {:server_error, "preview failed: " <> inspect(other)}

  @doc "The workspace a ticket belongs to (for authorisation), or nil."
  @spec ticket_workspace_id(String.t()) :: String.t() | nil
  def ticket_workspace_id(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{workspace_id: ws}} -> ws
      _ -> nil
    end
  end

  @doc "A JSON-ready map for a preview row."
  @spec serialize(Lease.t()) :: map()
  def serialize(%Lease{} = l) do
    %{
      repo: l.repo,
      task_id: l.task_id,
      workspace_id: l.workspace_id,
      status: l.status,
      port: l.port,
      url: l.url,
      error: l.error,
      checkout_kind: l.checkout_kind,
      checkout_path: l.checkout_path,
      checkout_note: l.checkout_note,
      log_path: l.log_path,
      started_at: l.started_at,
      touched_at: l.touched_at
    }
  end

  # ---- lifecycle -----------------------------------------------------------

  @doc """
  One pass over every live preview, stopping the ones that should not run:

    * the preview process is gone (a server restart orphaned the row) — marked failed;
    * its ticket is closed or merged (`verifying`/`closed`) or no longer exists;
    * it runs in the ticket's own worktree and that worktree was removed;
    * it has not been touched for the repo's `idle_ttl_seconds`.

  Returns `[{task_id, reason}]` for what it acted on.
  """
  @spec sweep(DateTime.t()) :: [{String.t(), String.t()}]
  def sweep(now \\ DateTime.utc_now()) do
    acted =
      for %Lease{} = row <- Leases.list(),
          row.port != nil,
          reason = sweep_reason(row, now) do
        case reason do
          :orphaned -> orphaned(row)
          reason -> stop_row(row, "auto-stopped: " <> reason)
        end

        {row.task_id, to_string(reason)}
      end

    if acted != [], do: broadcast()
    acted
  end

  defp sweep_reason(%Lease{} = row, now) do
    cond do
      Runner.whereis(row.repo, row.task_id) == nil ->
        :orphaned

      ticket_done?(row.task_id) ->
        "the ticket is closed or merged"

      (row.checkout_kind == "worktree" and row.checkout_path) && not File.dir?(row.checkout_path) ->
        "its worktree was removed"

      idle?(row, now) ->
        "idle too long"

      true ->
        nil
    end
  end

  defp ticket_done?(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{state: state}} -> state in [:verifying, :closed]
      _ -> true
    end
  end

  defp idle?(%Lease{touched_at: nil}, _now), do: false

  defp idle?(%Lease{} = row, now) do
    ttl =
      with ws when is_binary(ws) <- row.workspace_id,
           {:ok, %Workspace{} = workspace} <- Ash.get(Workspace, ws),
           {:ok, cfg} <- Config.resolve(workspace, row.repo) do
        cfg.idle_ttl_seconds
      else
        _ -> 7200
      end

    DateTime.diff(now, row.touched_at, :second) >= ttl
  end
end

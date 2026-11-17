defmodule Wardmast.Preview.Leases do
  @moduledoc """
  The persisted port lease table behind app previews (`preview_leases`).

  Collisions are impossible by construction, not by luck:

    * the candidate set is the configured range minus the server's own port, any
      caller-reserved port and every port a row already holds;
    * the range may never overlap `Wardmast.Worker.DevServerEnv`'s worker range
      (20000-29999) — refused here as well as at config-write time;
    * a candidate must pass a bind probe on 127.0.0.1;
    * the insert is guarded by a unique index on `port`, so even two racing
      acquirers cannot both hold one (the loser moves to the next candidate).

  A lease is released by nulling `port` (`release/1`) or deleting the row.
  """

  import Ecto.Query

  alias Wardmast.Preview.Config
  alias Wardmast.Preview.Lease
  alias Wardmast.Repo

  @doc """
  Lease a port from `range` (`{lo, hi}`) to the preview `attrs` (`:repo`,
  `:task_id`, and any other `Lease` field).

  Options: `:reserved` (extra ports never handed out), `:probe` (a 1-arity
  free-port check, default `port_free?/1`).

  A `(repo, task_id)` row that still holds a port is `{:error, {:already_leased,
  lease}}`; one that does not (failed) is replaced.
  """
  @spec acquire(map(), {pos_integer(), pos_integer()}, keyword()) ::
          {:ok, Lease.t()}
          | {:error,
             :range_exhausted | :range_overlaps_worker_ports | {:already_leased, Lease.t()}}
  def acquire(%{repo: repo, task_id: task_id} = attrs, {lo, hi} = range, opts \\ []) do
    {wlo, whi} = Config.worker_range()
    existing = get(repo, task_id)

    cond do
      lo <= whi and hi >= wlo ->
        {:error, :range_overlaps_worker_ports}

      existing != nil and existing.port != nil ->
        {:error, {:already_leased, existing}}

      true ->
        if existing, do: Repo.delete!(existing)
        probe = Keyword.get(opts, :probe, &port_free?/1)
        taken = MapSet.new(held_ports() ++ reserved(opts))
        take_first(attrs, candidates(range, taken), probe)
    end
  end

  defp take_first(_attrs, [], _probe), do: {:error, :range_exhausted}

  defp take_first(attrs, [port | rest], probe) do
    if probe.(port) do
      row =
        struct(
          Lease,
          Map.merge(
            %{status: "starting", started_at: now(), touched_at: now()},
            Map.put(attrs, :port, port)
          )
        )

      changeset =
        row
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint(:port)
        |> Ecto.Changeset.unique_constraint([:repo, :task_id])

      case Repo.insert(changeset) do
        {:ok, lease} ->
          {:ok, lease}

        {:error, %Ecto.Changeset{errors: errors}} ->
          # Another acquirer took this port: try the next. Another acquirer took
          # this (repo, task_id): that preview is theirs.
          if Keyword.has_key?(errors, :port),
            do: take_first(attrs, rest, probe),
            else: {:error, {:already_leased, get(attrs.repo, attrs.task_id)}}
      end
    else
      take_first(attrs, rest, probe)
    end
  end

  # Ascending order; the unique index, not the order, is what isolates previews.
  defp candidates({lo, hi}, taken) do
    all = Enum.to_list(lo..hi)
    Enum.reject(all, &(&1 in taken or &1 in worker_ports()))
  end

  defp worker_ports do
    {wlo, whi} = Config.worker_range()
    wlo..whi
  end

  defp reserved(opts), do: Keyword.get(opts, :reserved, []) ++ server_ports()

  @doc "The ports Wardmast itself serves on (the live server must never be leased)."
  @spec server_ports() :: [non_neg_integer()]
  def server_ports do
    endpoint = Application.get_env(:wardmast_web, :endpoint_module, WardmastWeb.Endpoint)

    [:http, :https]
    |> Enum.flat_map(fn key ->
      case Application.get_env(:wardmast_web, endpoint, []) |> Keyword.get(key) do
        opts when is_list(opts) ->
          case Keyword.get(opts, :port) do
            port when is_integer(port) -> [port]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  @doc "True when nothing is listening on `port` at 127.0.0.1."
  @spec port_free?(non_neg_integer()) :: boolean()
  def port_free?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true, active: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  @doc "The lease row for `(repo, task_id)`, or nil."
  @spec get(String.t(), String.t()) :: Lease.t() | nil
  def get(repo, task_id), do: Repo.get_by(Lease, repo: repo, task_id: task_id)

  @doc "Every preview row, newest first."
  @spec list() :: [Lease.t()]
  def list, do: Repo.all(from(l in Lease, order_by: [desc: l.inserted_at]))

  @doc "Ports currently leased."
  @spec held_ports() :: [non_neg_integer()]
  def held_ports,
    do: Repo.all(from(l in Lease, where: not is_nil(l.port), select: l.port))

  @doc "Update fields on a lease row."
  @spec update(Lease.t(), map()) :: {:ok, Lease.t()} | {:error, Ecto.Changeset.t()}
  def update(%Lease{} = lease, attrs) do
    lease
    |> Ecto.Changeset.cast(attrs, [
      :status,
      :os_pid,
      :url,
      :log_path,
      :checkout_path,
      :checkout_kind,
      :checkout_note,
      :error,
      :touched_at,
      :workspace_id
    ])
    |> Repo.update()
  end

  @doc "Release the port (row kept, `port` nil)."
  @spec release(Lease.t()) :: {:ok, Lease.t()} | {:error, Ecto.Changeset.t()}
  def release(%Lease{} = lease) do
    lease |> Ecto.Changeset.change(port: nil, os_pid: nil) |> Repo.update()
  end

  @doc "Delete the row (and with it the lease)."
  @spec delete(Lease.t()) :: :ok
  def delete(%Lease{} = lease) do
    _ = Repo.delete(lease, allow_stale: true)
    :ok
  end

  defp now, do: DateTime.utc_now()
end

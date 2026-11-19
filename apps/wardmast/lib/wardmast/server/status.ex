defmodule Wardmast.Server.Status do
  @moduledoc """
  The server's own identity and schema state, read by `GET /api/version`,
  `GET /api/server/migrations` and the `server_status` MCP tool, so the three
  cannot disagree. Every value is a version stamp, a timestamp, a count or a
  `owner/repo` — never a host path.
  """

  @doc "Version, git sha, build and boot timestamps, release repo, and the update-check block."
  @spec version() :: map()
  def version do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    booted_at =
      DateTime.utc_now()
      |> DateTime.add(-div(uptime_ms, 1000), :second)
      |> DateTime.to_iso8601()

    %{
      version: Wardmast.Version.app_version(),
      sha: Wardmast.Version.git_sha(),
      built_at: Wardmast.Version.built_at(),
      booted_at: booted_at,
      release_repo: Wardmast.Version.release_repo(),
      update: update()
    }
  end

  @doc "`Wardmast.Release.UpdateCheck`'s last result, JSON-shaped."
  @spec update() :: map()
  def update do
    u = Wardmast.Release.UpdateCheck.state()

    %{
      enabled: u.enabled,
      latest: u.latest,
      release_url: u.release_url,
      checked_at: u.checked_at && DateTime.to_iso8601(u.checked_at),
      update_available: u.update_available?,
      migrations_pending: u.migrations_pending,
      error: u.error
    }
  end

  @doc """
  The shared backend of the dashboard's "Check for updates" button,
  `POST /api/server/update_check` (`arb server update-check`) and the
  `update_check` MCP tool. Runs `UpdateCheck.check_limited/0` (at most one real
  GitHub call per minute; inside the window the cached result comes back with
  `cached: true`) and returns `%{latest, running, update_available, release_url,
  checked_at, cached, error}`; `error` is nil unless the check failed.
  """
  @spec update_check() :: map()
  def update_check do
    {kind, u} = Wardmast.Release.UpdateCheck.check_limited()

    %{
      latest: u.latest,
      running: Wardmast.Version.app_version(),
      update_available: u.update_available?,
      release_url: u.release_url,
      checked_at: u.checked_at && DateTime.to_iso8601(u.checked_at),
      cached: kind != :fresh,
      error: if(kind == :disabled, do: "update check is disabled on this server", else: u.error)
    }
  end

  @doc "Pending-migration status: `ok` (none), `warning` (some) or `unknown` (unreadable)."
  @spec migrations() :: map()
  def migrations do
    case Wardmast.Migrations.count_pending() do
      {:ok, 0} -> %{status: "ok", pending_count: 0}
      {:ok, count} -> %{status: "warning", pending_count: count}
      {:error, reason} -> %{status: "unknown", pending_count: nil, error: Atom.to_string(reason)}
    end
  end

  @doc """
  What the `server_status` MCP tool returns: the version read with the
  migration status folded in under `migrations`, and the update block at the
  top level.
  """
  @spec snapshot() :: map()
  def snapshot, do: Map.put(version(), :migrations, migrations())
end

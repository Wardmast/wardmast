defmodule Wardmast.NodeAgent.LegacyCleanup do
  @moduledoc """
  The one-time node cleanup of SI13 (`docs/design/remote-workers.md` §21.4, §21.6 step 6).

  With the CLI shelf and build-from-plan gone, `<node_home>/files/` (the shelf's
  content-addressed cache) holds nothing a run reads. `<node_home>/deps-seed/` is still
  the per-run staging scratch for `Wardmast.NodeAgent.Run` (`SeedLayer.install/3`'s stamp
  probe and the `seed_job` fallback `DepsCache.seed_checkout/3`), where each prepare call
  creates its own subdirectory (`File.mkdir_p!`) and removes it in `after`: at agent
  boot (`NodeAgent.Supervisor.init/1`, before `RunSupervisor` or `Connection` starts any
  run), anything left under `<node_home>/deps-seed/` is orphaned residue from an
  interrupted pre-SI13 seed job. The agent removes both directories once at startup — a
  marker file records that it did, so later runs' live scratch in `<node_home>/deps-seed/`
  is never touched. Old `localhost/arbiter-dev/*` images are not touched here (their tags
  are content hashes shared by every install on the host); the doctor lists them and the
  operator removes them.
  """

  require Logger

  @marker "legacy-cleanup-si13"
  @dirs ~w(files deps-seed)

  @doc "Remove the retired directories under `node_home` unless already done. `:ok | :skipped`."
  @spec run(String.t() | nil) :: :ok | :skipped
  def run(node_home) when is_binary(node_home) and node_home != "" do
    marker = Path.join(node_home, @marker)

    if File.exists?(marker) or not File.dir?(node_home) do
      :skipped
    else
      for dir <- @dirs, do: remove(Path.join(node_home, dir))
      File.write(marker, DateTime.utc_now() |> DateTime.to_iso8601())
      :ok
    end
  end

  def run(_node_home), do: :skipped

  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, [_ | _]} ->
        Logger.info("node agent: removed retired #{path}")

      {:ok, []} ->
        :ok

      {:error, reason, file} ->
        Logger.warning("node agent: cannot remove #{file}: #{inspect(reason)}")
    end
  end
end

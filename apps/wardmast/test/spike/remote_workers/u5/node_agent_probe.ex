# RW2 spike (bd-6tx1xv) U5 — NOT product code, never compiled by `mix`.
# Reports what a booted agent can and cannot see, then idles.
defmodule Wardmast.NodeAgent.Probe do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @reused [
    Wardmast.Worker.Container,
    Wardmast.Worker.PrivateClone,
    Wardmast.Worker.DepsCache,
    Wardmast.Worker.TestServices,
    Wardmast.Worker.PodmanReadiness,
    Wardmast.Worker.Image,
    Wardmast.Worker.Egress.Listener,
    Wardmast.Worker.Egress.Forward
  ]

  @impl true
  def init(_) do
    {:ok, %{}, {:continue, :report}}
  end

  @impl true
  def handle_continue(:report, state) do
    vm_ms = :erlang.statistics(:wall_clock) |> elem(0)
    rss_kb = rss_kb()

    loaded =
      for m <- @reused, into: %{}, do: {inspect(m), Code.ensure_loaded?(m)}

    # A pure call into reused product code: proves the modules run, not just load.
    name = Wardmast.Worker.Container.name_for("spike")

    report = %{
      os_time_ms: System.os_time(:millisecond),
      vm_wall_ms: vm_ms,
      rss_kb: rss_kb,
      role: Application.get_env(:wardmast, :role),
      repo_running: Process.whereis(Wardmast.Repo) != nil,
      vault_running: Process.whereis(Wardmast.Vault) != nil,
      endpoint_running: Process.whereis(WardmastWeb.Endpoint) != nil,
      secret_key_base_configured:
        Application.get_env(:wardmast_web, WardmastWeb.Endpoint)[:secret_key_base] != nil,
      cloak_key_env_present: System.get_env("ARBITER_CLOAK_KEY") != nil,
      started_apps: length(Application.started_applications()),
      loaded_modules: length(:code.all_loaded()),
      container_name_for: name,
      reused_modules_loadable: loaded
    }

    IO.puts("AGENT_READY " <> IO.iodata_to_binary(:json.encode(report)))
    {:noreply, state}
  end

  defp rss_kb do
    "/proc/self/status"
    |> File.read!()
    |> then(&Regex.run(~r/VmRSS:\s+(\d+) kB/, &1))
    |> List.last()
    |> String.to_integer()
  end
end

defmodule WardmastCli.Cmd.Doctor.SandboxKey do
  @moduledoc """
  `arb doctor`'s "sandbox backend key" check (bd-4j0nfe): flags a workspace
  that still stores the deprecated root `sandbox` key, naming the backend its
  runs actually use and the key that backend came from.

  The sandbox is read from `agent.security.sandbox` only. A root
  `sandbox.backend` (stored by a `force` write before the alias existed) is read
  by nothing, yet `arb config get sandbox` showed it, so an operator who set
  `sandbox.backend auto` saw `auto` while every run stayed on bwrap. The server
  now rewrites such writes and folds a stored key on boot
  (`Wardmast.Boot.ConfigMigrator.migrate_root_sandbox/1`, canonical winning),
  so this fires only on a server that has not restarted since upgrading.

  The effective backend named is the workspace-wide one: a per-repo
  `agent.security.repos.<repo>.sandbox.backend` can still tighten it.
  """

  alias WardmastCli.Client
  alias WardmastCli.Cmd.Doctor.Checks.Result

  @name "sandbox backend key"
  @canonical "agent.security.sandbox.backend"
  @default_backend "bwrap"

  @spec check() :: Result.t()
  def check do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} when is_list(list) ->
        check(list)

      _ ->
        %Result{
          name: @name,
          status: :na,
          detail: "could not read workspaces",
          blocks_readiness: false
        }
    end
  end

  @doc "The check over `GET /api/workspaces` rows (`%{\"name\", \"config\"}`)."
  @spec check([map()]) :: Result.t()
  def check(workspaces) when is_list(workspaces) do
    case Enum.flat_map(workspaces, &finding/1) do
      [] ->
        %Result{
          name: @name,
          status: :ok,
          detail: "no workspace stores the deprecated root `sandbox` key",
          blocks_readiness: false
        }

      findings ->
        %Result{
          name: @name,
          status: :warn,
          detail:
            "#{phrase(findings)} the deprecated root `sandbox` key, which nothing reads — " <>
              Enum.join(findings, "; "),
          hint:
            "The backend runs use is `#{@canonical}`. Set the one you want with " <>
              "`arb config set #{@canonical} <bwrap|auto|podman>`, then restart the server " <>
              "(`ward server restart`): the boot config migrator folds the root key into " <>
              "`agent.security.sandbox` (the canonical value wins). Without a restart: " <>
              "`bin/wardmast eval Wardmast.Release.migrate_config`.",
          blocks_readiness: false
        }
    end
  end

  defp finding(%{"config" => %{"sandbox" => root} = config} = ws) do
    name = Map.get(ws, "name") || Map.get(ws, "id") || "(unnamed)"
    {effective, source} = effective_backend(config)
    ["#{name}: #{ignored(root, effective)}effective backend #{effective} #{source}"]
  end

  defp finding(_ws), do: []

  defp effective_backend(config) do
    case get_in(config, ["agent", "security", "sandbox"]) do
      %{"backend" => backend} when is_binary(backend) -> {backend, "(from `#{@canonical}`)"}
      _ -> {@default_backend, "(the default; `#{@canonical}` is unset)"}
    end
  end

  # Only a root backend that disagrees is called out as ignored: an agreeing or
  # backend-less root key is dead config all the same, but changes nothing.
  defp ignored(%{"backend" => backend}, effective)
       when is_binary(backend) and backend != effective,
       do: "`sandbox.backend: #{backend}` is ignored, "

  defp ignored(_root, _effective), do: ""

  defp phrase([_]), do: "1 workspace stores"
  defp phrase(findings), do: "#{length(findings)} workspaces store"
end

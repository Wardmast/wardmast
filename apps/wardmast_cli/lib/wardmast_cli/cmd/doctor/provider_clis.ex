defmodule WardmastCli.Cmd.Doctor.ProviderClis do
  @moduledoc """
  The provider-CLI checks of `ward server doctor` (bd-5wfsj7): whether the server
  found `claude`, `codex` and agy/gemini, where, and at which version against the
  provider's minimum supported one.

  The detection is the *server's* (`GET /api/server/platform`, `clis`,
  `Wardmast.Agents.CliDetection`): the doctor may run on another machine or from a
  shell whose PATH differs from a GUI-launched server's. The same call carries
  `path_source`, how that PATH was built (`Wardmast.Boot.LoginShellPath`).

  A missing CLI warns (an install may not use that provider); an outdated one
  fails, because dispatch to that provider is refused. Neither blocks readiness
  (`arb start` must not wait on an agent CLI), and the hint is the vendor's
  install/upgrade command: text to copy, never run by the doctor.
  """

  alias WardmastCli.Cmd.Doctor.Checks.Result

  @doc "The checks for the platform's `clis` and `path_source` (both `nil` from an older server)."
  @spec checks([map()] | nil, map() | nil) :: [Result.t()]
  def checks(clis, path_source) do
    path_rows(path_source) ++ Enum.map(List.wrap(clis), &cli_row/1)
  end

  defp cli_row(%{"provider" => provider} = cli) do
    base = %Result{
      id: "provider_cli_" <> provider,
      group: :auth,
      name: "#{provider} CLI"
    }

    case cli["status"] do
      "ok" ->
        %{base | status: :ok, detail: "#{cli["version"]} at #{cli["path"]}"}

      "missing" ->
        %{base | status: :warn, detail: cli["detail"], hint: install_hint(cli, "install")}

      "outdated" ->
        %{
          base
          | status: :fail,
            detail:
              "#{cli["version"]} at #{cli["path"]} is below the minimum supported " <>
                "#{cli["min_version"]}; dispatch to #{provider} is refused",
            hint: install_hint(cli, "upgrade")
        }

      _ ->
        %{
          base
          | status: :warn,
            detail: "found at #{cli["path"]} but its version could not be read",
            hint: "Run `#{Path.basename(cli["path"] || provider)} --version` on the server host."
        }
    end
  end

  defp install_hint(cli, "install"), do: "Install it: `#{cli["install_command"]}`"
  defp install_hint(cli, "upgrade"), do: "Upgrade it: `#{cli["upgrade_command"]}`"

  defp path_rows(%{"source" => "login_shell"} = src) do
    added = Enum.join(List.wrap(src["added"]), ", ")

    [
      %Result{
        id: "server_path",
        group: :auth,
        name: "server PATH",
        status: :ok,
        detail: "resolved from the login shell #{src["shell"]} at boot (added #{added})"
      }
    ]
  end

  defp path_rows(%{"reason" => reason}) when is_binary(reason) do
    if String.contains?(reason, "resolve_failed") do
      [
        %Result{
          id: "server_path",
          group: :auth,
          name: "server PATH",
          status: :warn,
          detail: "the server's PATH is minimal and the login shell gave none: #{reason}",
          hint:
            "Launch the server from a shell that has the CLIs on PATH, or set PATH in its service environment."
        }
      ]
    else
      []
    end
  end

  defp path_rows(_), do: []
end

defmodule WardmastCli.Cmd.Doctor.DataHome do
  @moduledoc """
  `arb doctor`'s data-home split-brain check (bd-dt5f6c).

  A wrong data home means a wrong (empty) database, and nothing else says so.
  Four views of the home are compared:

    * the CLI's `Wardmast.Env.data_home/0`;
    * the home the installed plist / unit pins (`WARDMAST_DATA_HOME`);
      no pin at all is a legacy install and warns;
    * the running server's own home (`GET /api/server/platform`:
      `data_home`, `database_path`, `pid_file_path`);
    * where `<home>/current` points (it must live inside the home).

  Any disagreement is `:fail`, naming both paths and the fix. A live database
  outside the home (an explicit `DATABASE_PATH`) is allowed but `:warn`ed.

  Options (all optional; tests pass fixtures): `:cli_home`, `:unit_file`
  (path or `nil`), `:server` (map or `nil` when unreachable), `:current_target`.
  """

  alias WardmastCli.Client
  alias WardmastCli.Cmd.Doctor.Checks.Result
  alias WardmastCli.Cmd.ReleaseDeploy.ReleaseFiles

  @name "data home"
  @fix "Re-run `arb install service` from the shell whose WARDMAST_DATA_HOME you want, then `arb restart`."

  @spec check(keyword()) :: Result.t()
  def check(opts \\ []) do
    cli_home = Keyword.get_lazy(opts, :cli_home, &Wardmast.Env.data_home/0) |> norm()
    unit_file = Keyword.get_lazy(opts, :unit_file, &installed_unit_file/0)
    server = Keyword.get_lazy(opts, :server, &fetch_server/0)

    current =
      Keyword.get_lazy(opts, :current_target, fn ->
        ReleaseFiles.current_target(Path.join(cli_home, "current"))
      end)

    pin = pinned_home(unit_file)

    failures =
      pin_failures(pin, cli_home) ++
        server_failures(server, pin, cli_home) ++ current_failures(current, cli_home)

    warnings = pin_warnings(pin) ++ db_warnings(server, pin, cli_home)

    build(failures, warnings, cli_home, pin, server)
  end

  defp build([_ | _] = failures, warnings, _cli, _pin, _server) do
    %Result{
      name: @name,
      status: :fail,
      detail: "data-home split-brain: " <> Enum.join(failures ++ warnings, "; "),
      hint: @fix
    }
  end

  defp build([], [_ | _] = warnings, _cli, _pin, _server) do
    %Result{
      name: @name,
      status: :warn,
      detail: Enum.join(warnings, "; "),
      hint: @fix
    }
  end

  defp build([], [], cli_home, _pin, _server) do
    %Result{name: @name, status: :ok, detail: "#{cli_home} (CLI, unit and server agree)"}
  end

  defp pin_failures({:pinned, pin}, cli_home) do
    if norm(pin) == cli_home,
      do: [],
      else: [
        "the installed service pins WARDMAST_DATA_HOME=#{pin} but the CLI resolves #{cli_home}"
      ]
  end

  defp pin_failures(_, _), do: []

  defp pin_warnings(:legacy),
    do: [
      "the installed service pins no WARDMAST_DATA_HOME (legacy install); re-run `arb install service`"
    ]

  defp pin_warnings(_), do: []

  defp server_failures(%{"data_home" => srv} = _server, pin, cli_home) when is_binary(srv) do
    {what, expected} =
      case pin do
        {:pinned, p} -> {"the installed service pins", norm(p)}
        _ -> {"the CLI resolves", cli_home}
      end

    if norm(srv) == expected,
      do: [],
      else: ["the running server uses data home #{srv} but #{what} #{expected}"]
  end

  defp server_failures(_, _, _), do: []

  defp current_failures(nil, _), do: []

  defp current_failures(target, cli_home) do
    if inside?(target, cli_home),
      do: [],
      else: ["#{cli_home}/current points at #{target}, outside the data home"]
  end

  defp db_warnings(%{"database_path" => db} = server, pin, cli_home) when is_binary(db) do
    home =
      case {pin, server["data_home"]} do
        {{:pinned, p}, _} -> norm(p)
        {_, srv} when is_binary(srv) -> norm(srv)
        _ -> cli_home
      end

    if inside?(db, home),
      do: [],
      else: [
        "the live database #{db} is outside the data home #{home} (explicit DATABASE_PATH)"
      ]
  end

  defp db_warnings(_, _, _), do: []

  defp inside?(path, home), do: String.starts_with?(norm(path) <> "/", home <> "/")

  defp norm(path), do: path |> Path.expand() |> String.trim_trailing("/")

  # :none (no unit installed) | :legacy (installed, no pin) | {:pinned, path}
  defp pinned_home(nil), do: :none

  defp pinned_home(file) do
    case File.read(file) do
      {:ok, body} ->
        case pin_from(body) do
          nil -> if dev_mode?(body), do: :dev_unpinned, else: :legacy
          path -> {:pinned, path}
        end

      _ ->
        :none
    end
  end

  # A source-checkout (dev) install leaves the pin out on purpose unless the
  # installing shell exported WARDMAST_DATA_HOME, so it is not a legacy install.
  defp dev_mode?(body) do
    String.contains?(body, ".run-server.sh") or
      String.contains?(body, "[dev-mode source checkout]")
  end

  defp pin_from(body) do
    plist = Regex.run(~r{<key>WARDMAST_DATA_HOME</key>\s*<string>([^<]*)</string>}, body)
    unit = Regex.run(~r/^\s*Environment="?WARDMAST_DATA_HOME=([^"\n]*)"?\s*$/m, body)

    case plist || unit do
      [_, value] when value != "" -> unescape(value)
      _ -> nil
    end
  end

  defp unescape(v),
    do:
      v
      |> String.replace("&amp;", "&")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")

  defp installed_unit_file do
    sup = WardmastCli.Supervisor.impl()

    sup.unit_dirs()
    |> Enum.map(&Path.join(&1, sup.unit_file_name()))
    |> Enum.find(&File.regular?/1)
  end

  defp fetch_server do
    case Client.get("/api/server/platform") do
      {:ok, %{} = body} -> body
      _ -> nil
    end
  end
end

defmodule WardmastCli.Cmd.Support do
  @moduledoc """
  arb support bundle [--out <file>]

  Write a diagnostics archive (`.tar.gz`) for a bug report: server version,
  doctor snapshot, config and the tail of the server log. The server redacts
  known secret shapes and secret-looking config values
  (`Wardmast.Support.Bundle`); the dashboard's About page has the same button.
  Needs an operator token (`GET /api/support/bundle`).
  """

  alias WardmastCli.{ArgParser, Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _mode} =
        ArgParser.parse(argv, command: "ward support", switches: [out: :string, json: :boolean])

      case rest do
        ["bundle"] -> bundle(opts)
        _ -> Output.die("usage: ward support bundle [--out <file>]")
      end
    end
  end

  defp bundle(opts) do
    case Client.get("/api/support/bundle") do
      {:ok, %{"filename" => filename, "data_base64" => b64}} ->
        path = Path.expand(opts[:out] || filename)

        with {:ok, data} <- Base.decode64(b64),
             :ok <- File.write(path, data) do
          IO.puts("Wrote diagnostics bundle: #{path}")
        else
          other -> Output.die("could not write the bundle: #{inspect(other)}")
        end

      {:ok, _} ->
        Output.die("the server's bundle reply was malformed")

      {:error, %Client.Error{} = error} ->
        Output.die(error)
    end
  end
end

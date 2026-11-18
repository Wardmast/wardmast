defmodule WardmastCli.Cmd.Support do
  @moduledoc """
  arb support bundle [--out <file>]

  Write a diagnostics archive (`.tar.gz`) for a bug report: server version,
  platform snapshot, config and the tail of the server log, plus this CLI's
  `arb doctor` check results (`client/doctor-checks.txt`). The server redacts
  known secret shapes and secret-looking config values
  (`Wardmast.Support.Bundle`), including the doctor text; the dashboard's
  About page has the same button (without the CLI-side doctor checks).
  Needs an operator token (`GET /api/support/bundle`).
  """

  alias WardmastCli.{ArgParser, Client, Output}
  alias WardmastCli.Cmd.Doctor
  alias WardmastCli.Cmd.Doctor.Formatter

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

  # Every doctor check, as `arb doctor --all` prints them. The server redacts it.
  defp doctor_text do
    checks =
      Application.get_env(:wardmast_cli, :support_doctor_checks, fn ->
        Doctor.checks(spawn: :skip)
      end)

    {:ok, io} = StringIO.open("")
    previous = Process.group_leader()
    Process.group_leader(self(), io)

    try do
      Formatter.emit_text(checks.(), all: true)
    rescue
      e -> IO.puts("doctor checks unavailable: " <> Exception.message(e))
    after
      Process.group_leader(self(), previous)
    end

    {_, text} = StringIO.contents(io)
    StringIO.close(io)
    text
  end

  defp bundle(opts) do
    body = %{"extra_files" => %{"doctor-checks.txt" => doctor_text()}}

    case Client.post("/api/support/bundle", body) do
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

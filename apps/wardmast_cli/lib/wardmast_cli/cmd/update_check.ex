defmodule WardmastCli.Cmd.UpdateCheck do
  @moduledoc """
  `arb server update-check [--json]` — ask the server to check GitHub for a newer
  release now (the same action as the dashboard's "Check for updates" button and
  the `update_check` MCP tool).

  Prints latest, running, update_available, release_url and checked_at. The
  server rate-limits manual checks to one real GitHub call a minute; inside that
  window the cached result comes back and `cached` is true. Exits non-zero only
  when the check itself reported an error (or the server is unreachable).
  """

  alias WardmastCli.{ArgParser, Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {_opts, _rest, mode} =
        ArgParser.parse(argv, command: "ward server update-check", switches: [])

      case Client.post("/api/server/update_check", %{}) do
        {:ok, body} -> emit(body, mode)
        {:error, %Client.Error{} = err} -> Output.die(err)
      end
    end
  end

  defp emit(body, :json) do
    IO.puts(Jason.encode!(body))
    exit_on_error(body)
  end

  defp emit(body, :text) do
    IO.puts("latest:           #{body["latest"] || "unknown"}")
    IO.puts("running:          #{body["running"]}")
    IO.puts("update_available: #{body["update_available"] == true}")
    IO.puts("release_url:      #{body["release_url"] || "-"}")
    IO.puts("checked_at:       #{body["checked_at"] || "-"}#{cached_note(body)}")
    exit_on_error(body)
  end

  defp cached_note(%{"cached" => true}), do: " (cached)"
  defp cached_note(_), do: ""

  defp exit_on_error(%{"error" => err}) when is_binary(err) and err != "" do
    Output.die("update check failed: " <> err)
  end

  defp exit_on_error(_), do: :ok
end

defmodule WardmastCli.Cmd.Screenshots do
  @moduledoc """
  UI screenshots plan, checked before `arb done`:

      ward screenshots check [<ticket>]
                                        — validate .arbiter/screenshots.json the way the
                                          `arb done` commit gate will. Exits 1 when the branch
                                          touches the repo's ui_paths and the plan is missing or
                                          invalid. <ticket> defaults to $ARB_WORKER_BEAD_ID.

  A valid `skip` passes. With `plan_required: false` a missing plan passes and the repo's
  `default_routes` are shot instead. MCP twin: `screenshots_plan_check`.
  """

  alias WardmastCli.{ArgParser, Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {_opts, rest, mode} =
        ArgParser.parse(argv, command: "ward screenshots", switches: [])

      case rest do
        ["check" | args] -> check(List.first(args) || System.get_env("ARB_WORKER_BEAD_ID"), mode)
        _ -> unknown()
      end
    end
  end

  @spec unknown() :: no_return()
  defp unknown do
    IO.puts(:stderr, "ward: unknown screenshots subcommand")
    IO.puts(:stderr, "Run `ward screenshots --help` for usage.")
    Output.halt(2)
  end

  defp check(nil, _mode),
    do: Output.die("ward screenshots check requires: <ticket> (or $ARB_WORKER_BEAD_ID)")

  defp check(ticket, mode) do
    case Client.post("/api/issues/#{Client.path_segment(ticket)}/screenshots/check", %{}) do
      {:ok, body} ->
        if mode == :json, do: IO.puts(Jason.encode!(body)), else: print(body)
        if body["ok"] == false, do: Output.halt(1)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp print(body) do
    IO.puts("screenshots plan: #{body["status"]}")
    Enum.each(body["messages"] || [], &IO.puts("  " <> &1))
  end
end

defmodule WardmastCli.Cmd.Pair do
  @moduledoc """
  Pair on a ticket (bd-7p6a9o): a hands-on agent session bound to one ticket,
  worked together with you.

      ward pair <ticket>         open (or reopen) the ticket's pair session
      ward pair done <ticket>    Done: commit gate, then PR, ReviewGate, CI, merge queue
      ward pair end <ticket>     end the session without Done (worktree and branch kept)

  `ward pair <ticket>` launches the session in the ticket's own worktree, on
  its branch, and opens it in the dashboard's dock; attach from a terminal on
  this host with `ward session attach <session-id>`. While the session lives,
  no worker is dispatched on the ticket.

  `ward pair done <ticket>` waits for the commit gate — the repo's pre-push
  checks can take a few minutes. A red check prints its output and the session
  stays open: fix it, commit, and run Done again. On success the PR is opened
  labelled `pair-authored` (after the ReviewGate's approval, when the
  workspace requires review) and the session ends.

  `ward pair end <ticket>` ends the session and leaves everything else: a later
  pair session or a worker continues from the branch. Push before you end.

  Wraps `POST /api/issues/:id/pair`, `POST /api/issues/:id/pair/done` and
  `DELETE /api/issues/:id/pair`; the MCP twins are `pair_open`, `pair_done` and
  `pair_end`.
  """

  alias WardmastCli.{ArgParser, Client, Output}

  # The server waits up to ~280s on Done before answering "still running";
  # the HTTP call waits a little longer than that.
  @done_receive_timeout_ms 300_000

  @usage "usage: ward pair <ticket> | ward pair done <ticket> | ward pair end <ticket>"

  @spec run([String.t()]) :: :ok
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {_opts, rest, mode} = ArgParser.parse(argv, command: "ward pair", switches: [])

      case rest do
        ["done", id] -> done(id, mode)
        ["end", id] -> close(id, mode)
        [verb] when verb in ["done", "end"] -> Output.die("pair #{verb} requires a ticket id")
        [id] -> open(id, mode)
        [] -> Output.die("pair requires a ticket id", @usage)
        _ -> Output.die(@usage)
      end
    end
  end

  defp open(id, mode) do
    case Client.post(path(id), %{}) do
      {:ok, %{"data" => data} = body} -> emit(body, mode, fn -> print_opened(data) end)
      {:error, err} -> Output.die(err)
    end
  end

  defp done(id, mode) do
    case Client.post(path(id) <> "/done", %{}, receive_timeout: @done_receive_timeout_ms) do
      {:ok, %{"data" => data} = body} -> emit(body, mode, fn -> print_done(data) end)
      {:error, err} -> Output.die(err)
    end
  end

  defp close(id, mode) do
    case Client.delete(path(id)) do
      {:ok, %{"data" => data} = body} -> emit(body, mode, fn -> print_ended(data) end)
      {:error, err} -> Output.die(err)
    end
  end

  defp path(id), do: "/api/issues/" <> Client.path_segment(id) <> "/pair"

  defp emit(body, :json, _print), do: Output.emit_json(body)
  defp emit(_body, :text, print), do: print.()

  defp print_opened(data) do
    verb = if data["reopened"], do: "Reopened", else: "Opened"

    IO.puts("#{verb} pair session #{short(data["session_id"])} for #{data["ticket_id"]}")
    IO.puts("  name:     #{data["name"]}")
    IO.puts("  worktree: #{data["worktree"]}")

    IO.puts(
      "It is in the dashboard's dock; attach here with: ward session attach #{data["session_id"]}"
    )

    IO.puts(
      "Finish with `ward pair done #{data["ticket_id"]}`, or end it with `ward pair end #{data["ticket_id"]}`."
    )

    :ok
  end

  defp print_done(%{"route" => "running"} = data) do
    IO.puts(data["message"] || "Done is still running; watch the ticket for the outcome.")
    :ok
  end

  defp print_done(%{"route" => "in_review"} = data) do
    IO.puts(
      "Done: #{data["ticket_id"]} is with the ReviewGate. On approval its PR opens, labelled " <>
        "pair-authored, and goes through CI and the merge queue."
    )

    print_session_end(data)
  end

  defp print_done(data) do
    IO.puts(
      "Done: #{data["ticket_id"]}'s PR is open, labelled pair-authored, and in the merge " <>
        "queue's hands (CI, then merge)."
    )

    print_session_end(data)
  end

  defp print_session_end(%{"session_end" => "deferred"}) do
    IO.puts("The pair session ends in a moment.")
    :ok
  end

  defp print_session_end(_data) do
    IO.puts("The pair session has ended.")
    :ok
  end

  defp print_ended(data) do
    IO.puts("Ended pair session #{short(data["session_id"])} for #{data["ticket_id"]}.")
    IO.puts("The worktree and branch are kept: #{data["worktree"]}")
    :ok
  end

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(_id), do: "?"
end

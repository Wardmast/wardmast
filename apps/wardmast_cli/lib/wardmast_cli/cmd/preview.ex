defmodule WardmastCli.Cmd.Preview do
  @moduledoc """
  App previews: run a ticket's checkout as a live app on its own port.

      ward preview start <ticket> [--repo R] [--no-wait] [--timeout SECS]
                                        — start the repo's configured preview
                                          command in the ticket's checkout and
                                          print the URL once it answers
      ward preview stop  <ticket> [--repo R]
                                        — kill its whole process group, free the port
      ward preview list  [--workspace W]
                                        — every preview: state, port, URL, checkout
      ward preview show  <ticket> [--repo R]
                                        — one preview (a failed one prints its log tail)
      ward preview logs  <ticket> [-f] [--lines N] [--repo R]
                                        — the preview's log; -f follows it

  The command comes from `worker.repos.<repo>.preview` in the workspace config
  (docs/app-preview.md). The port is leased from a dedicated range
  (default 31000-31999) and the app is reached on 127.0.0.1. A live worker's
  checkout is never used or modified: with a worker running, or the ticket's
  checkout on a cluster node, the preview runs from a separate checkout and the
  output says so.

  `start` waits for the app to answer `ready_path` (up to the repo's
  `ready_timeout`) and exits 1 with the log tail when it fails; `--no-wait`
  returns as soon as it is starting.
  """

  alias WardmastCli.{ArgParser, Client, Output, Workspace}

  @poll_ms 1_000
  @follow_ms 1_000

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv,
          command: "ward preview",
          aliases: [f: :follow],
          switches: [
            workspace: :string,
            repo: :string,
            wait: :boolean,
            timeout: :integer,
            follow: :boolean,
            lines: :integer
          ]
        )

      case rest do
        ["start", ticket | _] -> start(ticket, opts, mode)
        ["stop", ticket | _] -> stop(ticket, opts, mode)
        ["list" | _] -> list(opts, mode)
        ["show", ticket | _] -> show(ticket, opts, mode)
        ["logs", ticket | _] -> logs(ticket, opts, mode)
        [verb | _] when verb in ["start", "stop", "show", "logs"] -> needs_ticket(verb)
        _ -> unknown()
      end
    end
  end

  @spec unknown() :: no_return()
  defp unknown do
    IO.puts(:stderr, "ward: unknown preview subcommand")
    IO.puts(:stderr, "Run `ward preview --help` for usage.")
    Output.halt(2)
  end

  @spec needs_ticket(String.t()) :: no_return()
  defp needs_ticket(verb), do: Output.die("ward preview #{verb} requires: <ticket>")

  # ---- start ---------------------------------------------------------------

  defp start(ticket, opts, mode) do
    body = %{task_id: ticket} |> put_opt(opts, :repo)

    case Client.post("/api/previews", body) do
      {:ok, %{"preview" => preview}} ->
        preview =
          if Keyword.get(opts, :wait, true), do: await(ticket, preview, opts), else: preview

        finish_start(preview, mode)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp await(ticket, %{"status" => "starting"} = preview, opts) do
    deadline = System.monotonic_time(:second) + Keyword.get(opts, :timeout, 600)
    announce(preview)
    poll(ticket, opts, deadline)
  end

  defp await(_ticket, preview, _opts), do: preview

  defp poll(ticket, opts, deadline) do
    Process.sleep(@poll_ms)

    case Client.get("/api/previews/#{Client.path_segment(ticket)}", repo_params(opts)) do
      {:ok, %{"preview" => %{"status" => "starting"}}} ->
        if System.monotonic_time(:second) >= deadline,
          do:
            Output.die(
              "preview of #{ticket} is still starting after the timeout (see `ward preview logs #{ticket}`)",
              "it keeps starting in the background; `ward preview stop #{ticket}` cancels it"
            ),
          else: poll(ticket, opts, deadline)

      {:ok, %{"preview" => preview}} ->
        preview

      {:error, err} ->
        Output.die(err)
    end
  end

  defp announce(preview) do
    if note = preview["checkout_note"], do: IO.puts(:stderr, "note: #{note}")
    IO.puts(:stderr, "starting preview of #{preview["task_id"]} on port #{preview["port"]} ...")
  end

  defp finish_start(preview, :json) do
    IO.puts(Jason.encode!(%{preview: preview}))
    if preview["status"] == "failed", do: Output.halt(1)
  end

  defp finish_start(%{"status" => "running"} = preview, _mode) do
    if note = preview["checkout_note"], do: IO.puts(:stderr, "note: #{note}")
    IO.puts(preview["url"])
  end

  defp finish_start(%{"status" => "failed"} = preview, _mode) do
    print_failure(preview)
    Output.halt(1)
  end

  defp finish_start(preview, _mode) do
    if note = preview["checkout_note"], do: IO.puts(:stderr, "note: #{note}")

    IO.puts(
      "starting: #{preview["task_id"]} on port #{preview["port"]} " <>
        "(`ward preview show #{preview["task_id"]}`)"
    )
  end

  defp print_failure(preview) do
    IO.puts(:stderr, "ward: preview of #{preview["task_id"]} failed: #{preview["error"]}")

    case preview["log_tail"] do
      tail when is_binary(tail) and tail != "" ->
        IO.puts(:stderr, "--- log tail ---")
        IO.puts(:stderr, String.trim_trailing(tail))

      _ ->
        :ok
    end
  end

  # ---- stop / show / list --------------------------------------------------

  defp stop(ticket, opts, mode) do
    case Client.post(
           "/api/previews/#{Client.path_segment(ticket)}/stop",
           put_opt(%{}, opts, :repo)
         ) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          for p <- body["stopped"] || [] do
            IO.puts(
              "stopped preview of #{p["task_id"]} (#{p["repo"]}); port #{p["port"] || "-"} freed"
            )
          end
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp show(ticket, opts, mode) do
    case Client.get("/api/previews/#{Client.path_segment(ticket)}", repo_params(opts)) do
      {:ok, %{"preview" => p} = body} ->
        if mode == :json, do: IO.puts(Jason.encode!(body)), else: print_one(p)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp print_one(p) do
    IO.puts("#{p["task_id"]}  #{p["repo"]}  #{p["status"]}")
    if p["url"], do: IO.puts("  url:      #{p["url"]}")
    if p["port"], do: IO.puts("  port:     #{p["port"]}")
    IO.puts("  checkout: #{p["checkout_kind"]}  #{p["checkout_path"]}")
    if p["checkout_note"], do: IO.puts("  note:     #{p["checkout_note"]}")
    IO.puts("  log:      #{p["log_path"]}")
    if p["status"] == "failed", do: print_failure(p)
  end

  defp list(opts, mode) do
    params = if id = Workspace.selected_id(opts[:workspace]), do: [workspace: id], else: []

    case Client.get("/api/previews", params) do
      {:ok, body} ->
        if mode == :json,
          do: IO.puts(Jason.encode!(body)),
          else: print_list(body["previews"] || [])

      {:error, err} ->
        Output.die(err)
    end
  end

  defp print_list([]), do: IO.puts("No app previews.")

  defp print_list(previews) do
    Enum.each(previews, fn p ->
      IO.puts(
        String.pad_trailing(p["task_id"], 14) <>
          String.pad_trailing(p["status"], 10) <>
          String.pad_trailing(to_string(p["url"] || p["error"] || "-"), 30) <>
          "#{p["repo"]}  [#{p["checkout_kind"]}]"
      )
    end)
  end

  # ---- logs ----------------------------------------------------------------

  defp logs(ticket, opts, mode) do
    base = repo_params(opts) ++ if(n = opts[:lines], do: [lines: n], else: [])
    follow? = Keyword.get(opts, :follow, false)

    case fetch_logs(ticket, base) do
      {:ok, body} ->
        if mode == :json and not follow? do
          IO.puts(Jason.encode!(body))
        else
          IO.write(body["content"])
          if follow?, do: follow(ticket, opts, body["offset"])
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp follow(ticket, opts, offset) do
    Process.sleep(@follow_ms)

    case fetch_logs(ticket, repo_params(opts) ++ [offset: offset]) do
      {:ok, body} ->
        IO.write(body["content"])
        follow(ticket, opts, body["offset"])

      {:error, err} ->
        Output.die(err)
    end
  end

  defp fetch_logs(ticket, params),
    do: Client.get("/api/previews/#{Client.path_segment(ticket)}/logs", params)

  # ---- helpers -------------------------------------------------------------

  defp repo_params(opts), do: if(r = opts[:repo], do: [repo: r], else: [])

  defp put_opt(body, opts, key) do
    case opts[key] do
      nil -> body
      value -> Map.put(body, key, value)
    end
  end
end

defmodule WardmastCli.Cmd.PairTest do
  @moduledoc """
  bd-7p6a9o: `ward pair <ticket>`, `ward pair done <ticket>` and `ward pair end
  <ticket>` — the CLI twins of MCP `pair_open`, `pair_done` and `pair_end`.
  """
  use WardmastCli.CliCase, async: true

  alias WardmastCli.Cmd.Pair

  @session %{
    "session_id" => "5b1e0c2a-0000-4000-8000-000000000009",
    "name" => "Pair bd-001: Make widgets faster",
    "ticket_id" => "bd-001",
    "worktree" => "/srv/worktrees/feature-bd-001-make-widgets-faster",
    "status" => "starting",
    "end_reason" => nil
  }

  describe "ward pair <ticket>" do
    test "opens the pair session and says where it is and how to attach" do
      stub_routes([
        {{"post", "/api/issues/bd-001/pair"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"data" => Map.put(@session, "reopened", false)})
         end}
      ])

      {out, _err, exit_code} = capture(fn -> Pair.run(["bd-001"]) end)

      assert exit_code == 0
      assert out =~ "Opened pair session 5b1e0c2a"
      assert out =~ "bd-001"
      assert out =~ "/srv/worktrees/feature-bd-001-make-widgets-faster"
      assert out =~ "ward session attach 5b1e0c2a-0000-4000-8000-000000000009"
    end

    test "says when it reopened the live one" do
      stub_routes([
        {{"post", "/api/issues/bd-001/pair"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"data" => Map.put(@session, "reopened", true)})
         end}
      ])

      {out, _err, 0} = capture(fn -> Pair.run(["bd-001"]) end)
      assert out =~ "Reopened pair session 5b1e0c2a"
    end

    test "--json prints the server's data" do
      stub_routes([
        {{"post", "/api/issues/bd-001/pair"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"data" => Map.put(@session, "reopened", false)})
         end}
      ])

      {out, _err, 0} = capture(fn -> Pair.run(["bd-001", "--json"]) end)
      assert %{"data" => %{"session_id" => _, "reopened" => false}} = Jason.decode!(out)
    end

    test "a refusal is reported with the server's reason" do
      stub_routes([
        {{"post", "/api/issues/bd-001/pair"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(409)
           |> Req.Test.json(%{
             "error" => %{
               "type" => "conflict",
               "message" =>
                 "That ticket cannot be paired on: only a Backlog, Ready or In-progress ticket can.",
               "details" => %{}
             }
           })
         end}
      ])

      {_out, err, exit_code} = capture(fn -> Pair.run(["bd-001"]) end)
      assert exit_code != 0
      assert err =~ "cannot be paired on"
    end

    test "with no ticket, says so without calling the server" do
      {_out, err, exit_code} = capture(fn -> Pair.run([]) end)
      assert exit_code != 0
      assert err =~ "ticket id"
    end
  end

  describe "ward pair done <ticket>" do
    test "reports the route Done took" do
      stub_routes([
        {{"post", "/api/issues/bd-001/pair/done"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "data" => %{
               "ticket_id" => "bd-001",
               "route" => "in_review",
               "session_end" => "ended"
             }
           })
         end}
      ])

      {out, _err, exit_code} = capture(fn -> Pair.run(["done", "bd-001"]) end)

      assert exit_code == 0
      assert out =~ "ReviewGate"
      assert out =~ "pair-authored"
    end

    test "a red pre-push check prints its output and fails" do
      stub_routes([
        {{"post", "/api/issues/bd-001/pair/done"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(409)
           |> Req.Test.json(%{
             "error" => %{
               "type" => "conflict",
               "message" => "Done refused: a pre-push check failed.\n\nlint-failed-here",
               "details" => %{}
             }
           })
         end}
      ])

      {_out, err, exit_code} = capture(fn -> Pair.run(["done", "bd-001"]) end)
      assert exit_code != 0
      assert err =~ "lint-failed-here"
    end

    test "with no ticket, says so" do
      {_out, err, exit_code} = capture(fn -> Pair.run(["done"]) end)
      assert exit_code != 0
      assert err =~ "ticket id"
    end
  end

  describe "ward pair end <ticket>" do
    test "ends the session and says the worktree and branch are kept" do
      stub_routes([
        {{"delete", "/api/issues/bd-001/pair"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "data" => %{@session | "status" => "ended", "end_reason" => "closed"}
           })
         end}
      ])

      {out, _err, exit_code} = capture(fn -> Pair.run(["end", "bd-001"]) end)

      assert exit_code == 0
      assert out =~ "Ended pair session 5b1e0c2a"
      assert out =~ "worktree and branch are kept"
    end
  end
end

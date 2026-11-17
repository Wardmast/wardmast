defmodule WardmastCli.Cmd.PreviewTest do
  @moduledoc "`ward preview start|stop|list|show|logs`."
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Cmd.Preview

  @starting %{
    "task_id" => "bd-1",
    "repo" => "app",
    "status" => "starting",
    "port" => 31_007,
    "url" => nil,
    "checkout_kind" => "worktree",
    "checkout_note" => nil,
    "log_path" => "/p/preview.log"
  }
  @running Map.merge(@starting, %{"status" => "running", "url" => "http://127.0.0.1:31007/"})

  test "start prints the URL once the preview is running" do
    stub_routes([
      {{"post", "/api/previews"}, {%{"preview" => @starting}, 201}},
      {{"get", "/api/previews/bd-1"}, {%{"preview" => @running}, 200}}
    ])

    {out, err, code} = capture(fn -> Preview.run(["start", "bd-1"]) end)
    assert code == 0
    assert String.trim(out) == "http://127.0.0.1:31007/"
    assert err =~ "starting preview of bd-1 on port 31007"
  end

  test "start says which checkout it used when it is not the ticket's own" do
    snap =
      Map.merge(@running, %{
        "checkout_kind" => "snapshot",
        "checkout_note" => "A worker is live in the ticket's checkout, so ..."
      })

    stub_routes([{{"post", "/api/previews"}, {%{"preview" => snap}, 201}}])
    {out, err, code} = capture(fn -> Preview.run(["start", "bd-1"]) end)
    assert code == 0
    assert out =~ "http://127.0.0.1:31007/"
    assert err =~ "note: A worker is live"
  end

  test "start exits 1 and prints the reason and log tail when the preview fails" do
    failed =
      Map.merge(@starting, %{
        "status" => "failed",
        "port" => nil,
        "error" => "exited before it was ready with status 3",
        "log_tail" => "** (Mix) boom\n"
      })

    stub_routes([{{"post", "/api/previews"}, {%{"preview" => failed}, 201}}])
    {out, err, code} = capture(fn -> Preview.run(["start", "bd-1"]) end)
    assert code == 1
    assert out == ""
    assert err =~ "preview of bd-1 failed: exited before it was ready with status 3"
    assert err =~ "** (Mix) boom"
  end

  test "start --no-wait returns while it is still starting" do
    stub_routes([{{"post", "/api/previews"}, {%{"preview" => @starting}, 201}}])
    {out, _err, code} = capture(fn -> Preview.run(["start", "bd-1", "--no-wait"]) end)
    assert code == 0
    assert out =~ "starting: bd-1 on port 31007"
  end

  test "start surfaces a server error (no preview config)" do
    err_body = %{
      "error" => %{
        "type" => "invalid_request",
        "message" => "repo app has no preview configured: set worker.repos.app.preview.command",
        "details" => %{}
      }
    }

    stub_routes([{{"post", "/api/previews"}, {err_body, 400}}])
    {_out, err, code} = capture(fn -> Preview.run(["start", "bd-1"]) end)
    assert code == 1
    assert err =~ "worker.repos.app.preview.command"
  end

  test "stop reports the freed port" do
    stub_routes([
      {{"post", "/api/previews/bd-1/stop"},
       {%{"task_id" => "bd-1", "stopped" => [@running]}, 200}}
    ])

    {out, _err, code} = capture(fn -> Preview.run(["stop", "bd-1"]) end)
    assert code == 0
    assert out =~ "stopped preview of bd-1"
    assert out =~ "31007"
  end

  test "list prints one row per preview, or says there are none" do
    stub_get("/api/previews", %{"previews" => [@running]}, 200)
    {out, _err, 0} = capture(fn -> Preview.run(["list"]) end)
    assert out =~ "bd-1"
    assert out =~ "running"
    assert out =~ "http://127.0.0.1:31007/"

    stub_get("/api/previews", %{"previews" => []}, 200)
    {out, _err, 0} = capture(fn -> Preview.run(["list"]) end)
    assert out =~ "No app previews."
  end

  test "list --json passes the body through" do
    stub_get("/api/previews", %{"previews" => [@running]}, 200)
    {out, _err, 0} = capture(fn -> Preview.run(["list", "--json"]) end)
    assert %{"previews" => [%{"task_id" => "bd-1"}]} = Jason.decode!(out)
  end

  test "show prints url, checkout and note" do
    p = Map.put(@running, "checkout_note", "Read-only preview checkout of b at abc")
    stub_get("/api/previews/bd-1", %{"preview" => p}, 200)
    {out, _err, 0} = capture(fn -> Preview.run(["show", "bd-1"]) end)
    assert out =~ "url:      http://127.0.0.1:31007/"
    assert out =~ "Read-only preview checkout"
  end

  test "logs prints the content" do
    stub_get(
      "/api/previews/bd-1/logs",
      %{"content" => "line one\nline two\n", "offset" => 18},
      200
    )

    {out, _err, 0} = capture(fn -> Preview.run(["logs", "bd-1"]) end)
    assert out == "line one\nline two\n"
  end

  test "usage errors" do
    {_out, err, code} = capture(fn -> Preview.run(["start"]) end)
    assert code == 1
    assert err =~ "ward preview start requires: <ticket>"

    {_out, err, code} = capture(fn -> Preview.run(["bogus"]) end)
    assert code == 2
    assert err =~ "unknown preview subcommand"
  end
end

defmodule WardmastWeb.Api.PreviewControllerTest do
  @moduledoc "The transport behind `ward preview start|stop|list|logs`."
  use WardmastWeb.ConnCase, async: false

  alias Wardmast.Preview
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker.BranchNamer
  alias Wardmast.Worker.Worktree

  @server ~S"""
  use IO::Socket::INET; $| = 1;
  my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $ENV{PORT},
    Listen => 5, ReuseAddr => 1) or die "bind: $!";
  print "listening on $ENV{PORT}\n";
  while (my $c = $s->accept) { my $r = <$c>; print $c "HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nok\n"; close $c }
  """

  setup do
    fx = Wardmast.Test.GitFixture.origin_and_clone()

    prior =
      for key <- [:preview_root, :worktree_root], do: {key, Application.get_env(:wardmast, key)}

    Application.put_env(:wardmast, :preview_root, Path.join(fx.root, "previews"))
    Application.put_env(:wardmast, :worktree_root, Path.join(fx.root, "worktrees"))

    on_exit(fn ->
      Enum.each(Preview.list(), &Preview.stop(&1.task_id))

      Enum.each(prior, fn
        {k, nil} -> Application.delete_env(:wardmast, k)
        {k, v} -> Application.put_env(:wardmast, k, v)
      end)
    end)

    script = Path.join(fx.root, "server.pl")
    File.write!(script, @server)
    base = 32_000 + rem(System.unique_integer([:positive]), 90) * 10

    ws =
      Ash.create!(Workspace, %{
        name: "preview-api-#{System.unique_integer([:positive])}",
        config: %{
          "repo_paths" => %{"app" => fx.clone, "bare" => fx.clone},
          "worker" => %{
            "repos" => %{
              "app" => %{
                "preview" => %{
                  "command" => "perl #{script}",
                  "ready_timeout" => 20,
                  "port_range" => "#{base}-#{base + 9}"
                }
              }
            }
          }
        }
      })

    {:ok, Map.merge(fx, %{ws: ws})}
  end

  defp ticket!(ctx, repo, worktree? \\ true) do
    issue =
      Ash.create!(Issue, %{
        title: "api preview #{System.unique_integer([:positive])}",
        workspace_id: ctx.ws.id,
        repo: repo
      })

    if worktree? do
      path = issue |> BranchNamer.derive() |> Worktree.worktree_path()
      File.mkdir_p!(Path.dirname(path))

      Wardmast.Test.GitFixture.git!(ctx.clone, [
        "worktree",
        "add",
        "-q",
        "-b",
        BranchNamer.derive(issue),
        path
      ])
    end

    issue
  end

  test "start (wait), show, list, logs, stop over REST", %{conn: conn} = ctx do
    issue = ticket!(ctx, "app")

    resp =
      conn
      |> post("/api/previews", %{"task_id" => issue.id, "wait" => true})
      |> json_response(201)

    assert %{"status" => "running", "url" => url, "port" => port} = resp["preview"]
    assert url == "http://127.0.0.1:#{port}/"
    assert resp["preview"]["checkout_kind"] == "worktree"

    assert %{"preview" => %{"status" => "running"}} =
             conn |> get("/api/previews/#{issue.id}") |> json_response(200)

    assert %{"previews" => [%{"task_id" => tid}]} =
             conn |> get("/api/previews", %{"workspace" => ctx.ws.id}) |> json_response(200)

    assert tid == issue.id

    logs = conn |> get("/api/previews/#{issue.id}/logs") |> json_response(200)
    assert logs["content"] =~ "listening on #{port}"

    assert %{"content" => "", "offset" => off} =
             conn
             |> get("/api/previews/#{issue.id}/logs", %{"offset" => logs["offset"]})
             |> json_response(200)

    assert off == logs["offset"]

    assert %{"stopped" => [%{"port" => ^port}]} =
             conn |> post("/api/previews/#{issue.id}/stop") |> json_response(200)

    assert Wardmast.Preview.Leases.port_free?(port)
    assert conn |> get("/api/previews/#{issue.id}") |> json_response(404)
    assert %{"previews" => []} = conn |> get("/api/previews") |> json_response(200)
  end

  test "a failed preview shows its log tail", %{conn: conn} = ctx do
    # `bare` has no preview config; point a config at a failing command instead
    {:ok, _} =
      Ash.update(ctx.ws, %{
        config:
          put_in(ctx.ws.config, ["worker", "repos", "bare"], %{
            "preview" => %{"command" => "echo kaboom; exit 2", "port_range" => "32900-32909"}
          })
      })

    issue = ticket!(ctx, "bare")

    resp =
      conn
      |> post("/api/previews", %{"task_id" => issue.id, "wait" => true})
      |> json_response(201)

    assert resp["preview"]["status"] == "failed"
    assert resp["preview"]["error"] =~ "status 2"
    assert resp["preview"]["log_tail"] =~ "kaboom"
    assert resp["preview"]["port"] == nil
  end

  test "errors: no config, unknown ticket, no checkout", %{conn: conn} = ctx do
    other = ticket!(ctx, "bare")

    assert %{"error" => %{"type" => "invalid_request", "message" => msg}} =
             conn |> post("/api/previews", %{"task_id" => other.id}) |> json_response(400)

    assert msg =~ "worker.repos.bare.preview.command"

    assert conn |> post("/api/previews", %{"task_id" => "bd-nope"}) |> json_response(404)
    assert conn |> post("/api/previews", %{}) |> json_response(400)

    no_checkout = ticket!(ctx, "app", false)

    assert %{"error" => %{"type" => "not_found", "message" => msg}} =
             conn |> post("/api/previews", %{"task_id" => no_checkout.id}) |> json_response(404)

    assert msg =~ "no checkout to preview"
    assert conn |> post("/api/previews/#{other.id}/stop") |> json_response(404)
  end
end

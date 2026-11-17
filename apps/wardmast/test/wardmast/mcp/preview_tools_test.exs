defmodule Wardmast.MCP.PreviewToolsTest do
  @moduledoc "The MCP twins of `ward preview start|stop|list|logs`."
  use Wardmast.DataCase, async: false

  alias Wardmast.MCP.Catalog
  alias Wardmast.MCP.Scope
  alias Wardmast.MCP.Tools
  alias Wardmast.Preview
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.GitFixture
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
    fx = GitFixture.origin_and_clone()

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
    base = 32_500 + rem(System.unique_integer([:positive]), 40) * 10

    ws =
      Ash.create!(Workspace, %{
        name: "preview-mcp-#{System.unique_integer([:positive])}",
        config: %{
          "repo_paths" => %{"app" => fx.clone},
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

    issue =
      Ash.create!(Issue, %{title: "mcp preview", workspace_id: ws.id, repo: "app"})

    branch = BranchNamer.derive(issue)
    path = Worktree.worktree_path(branch)
    File.mkdir_p!(Path.dirname(path))
    GitFixture.git!(fx.clone, ["worktree", "add", "-q", "-b", branch, path])

    {:ok, ws: ws, issue: issue, coordinator: %Scope{tier: :coordinator, workspace_id: ws.id}}
  end

  test "the four tools are coordinator-only catalog entries" do
    for name <- ~w(preview_start preview_stop preview_list preview_logs) do
      assert {:ok, tool} = Catalog.fetch(name)
      assert tool.tiers == [:coordinator]
    end
  end

  test "start (wait), list, logs, stop", %{coordinator: scope, issue: issue} do
    assert {:ok, %{preview: %{status: "running", port: port, url: url}}} =
             Tools.preview_start(scope, %{"task_id" => issue.id, "wait" => true})

    assert url == "http://127.0.0.1:#{port}/"

    assert {:ok, %{previews: [%{task_id: tid}]}} = Tools.preview_list(scope, %{})
    assert tid == issue.id

    assert {:ok, %{preview: %{port: ^port}}} =
             Tools.preview_list(scope, %{"task_id" => issue.id})

    assert {:ok, %{content: log, offset: off}} =
             Tools.preview_logs(scope, %{"task_id" => issue.id})

    assert log =~ "listening on #{port}"

    assert {:ok, %{content: "", offset: ^off}} =
             Tools.preview_logs(scope, %{"task_id" => issue.id, "offset" => off})

    assert {:ok, %{stopped: [%{port: ^port}]}} =
             Tools.preview_stop(scope, %{"task_id" => issue.id})

    assert Wardmast.Preview.Leases.port_free?(port)
    assert {:ok, %{previews: []}} = Tools.preview_list(scope, %{})
    assert {:error, {:not_found, _}} = Tools.preview_stop(scope, %{"task_id" => issue.id})
  end

  test "errors are typed: unknown ticket, no preview config, other workspace", %{
    coordinator: scope,
    issue: issue
  } do
    assert {:error, {:not_found, _}} = Tools.preview_start(scope, %{"task_id" => "bd-nope"})
    assert {:error, {:invalid, _}} = Tools.preview_start(scope, %{})

    assert {:error, {:invalid_request, msg}} =
             Tools.preview_start(scope, %{"task_id" => issue.id, "repo" => "elsewhere"})

    assert msg =~ "worker.repos.elsewhere.preview.command"

    other = Ash.create!(Workspace, %{name: "preview-other-#{System.unique_integer([:positive])}"})
    foreign = %Scope{tier: :coordinator, workspace_id: other.id}
    assert {:error, {:not_found, _}} = Tools.preview_start(foreign, %{"task_id" => issue.id})
  end
end

defmodule WardmastWeb.PreviewLiveTest do
  @moduledoc "The Preview button, state panel and global list on the dashboard."
  use WardmastWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
    base = 33_000 + rem(System.unique_integer([:positive]), 90) * 10
    {:ok, Map.merge(fx, %{script: script, base: base})}
  end

  defp setup_ticket(ctx, command, preview_extra \\ %{}) do
    preview =
      Map.merge(
        %{
          "command" => command,
          "ready_timeout" => 20,
          "port_range" => "#{ctx.base}-#{ctx.base + 9}"
        },
        preview_extra
      )

    ws =
      Ash.create!(Workspace, %{
        name: "preview-live-#{System.unique_integer([:positive])}",
        config: %{
          "repo_paths" => %{"app" => ctx.clone, "bare" => ctx.clone},
          "worker" => %{"repos" => %{"app" => %{"preview" => preview}}}
        }
      })

    issue = Ash.create!(Issue, %{title: "live preview", workspace_id: ws.id, repo: "app"})
    branch = BranchNamer.derive(issue)
    path = Worktree.worktree_path(branch)
    File.mkdir_p!(Path.dirname(path))
    GitFixture.git!(ctx.clone, ["worktree", "add", "-q", "-b", branch, path])
    {ws, issue}
  end

  # The ticket page loads its body asynchronously.
  defp mount_task(conn, issue) do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{issue.id}")
    render_async(view, WardmastWeb.Test.Timing.scale(15_000))
    view
  end

  # Stop whatever is left and let the page see it, so nothing broadcasts to a
  # LiveView while the test's sandbox is being torn down.
  defp settle(view) do
    Enum.each(Preview.list(), &Preview.stop(&1.task_id))
    _ = render(view)
    :ok
  end

  defp eventually(view, selector, tries \\ 100) do
    cond do
      has_element?(view, selector) -> :ok
      tries == 0 -> flunk("#{selector} never appeared:\n#{render(view)}")
      true -> Process.sleep(100) && eventually(view, selector, tries - 1)
    end
  end

  test "Preview button starts the preview; URL shown when running; Stop clears it",
       %{conn: conn} = ctx do
    {_ws, issue} = setup_ticket(ctx, "perl #{ctx.script}")
    view = mount_task(conn, issue)

    assert has_element?(view, "#panel-preview #preview-start-btn")
    refute has_element?(view, "#preview-url")

    view |> element("#preview-start-btn") |> render_click()
    eventually(view, "#preview-url")

    assert %{row: %{port: port, url: url}} = Preview.overview(issue.id)
    assert has_element?(view, ~s|#preview-url[href="#{url}"]|)
    assert has_element?(view, "#preview-stop-btn")
    refute has_element?(view, "#preview-start-btn")
    assert Preview.Leases.held_ports() == [port]

    view |> element("#preview-stop-btn") |> render_click()
    eventually(view, "#preview-start-btn")
    refute has_element?(view, "#preview-url")
    assert Preview.Leases.port_free?(port)
    settle(view)
  end

  test "a failed start shows the error and a log tail, with Retry", %{conn: conn} = ctx do
    {_ws, issue} = setup_ticket(ctx, "echo kaboom-from-the-app; exit 2")
    view = mount_task(conn, issue)

    view |> element("#preview-start-btn") |> render_click()
    eventually(view, "#preview-error")

    assert render(view) =~ "status 2"
    assert has_element?(view, "#preview-log-tail", "kaboom-from-the-app")
    assert has_element?(view, "#preview-start-btn")
    settle(view)
  end

  test "an unconfigured repo shows how to configure it, with no button", %{conn: conn} = ctx do
    {ws, _} = setup_ticket(ctx, "true")
    other = Ash.create!(Issue, %{title: "no cfg", workspace_id: ws.id, repo: "bare"})
    view = mount_task(conn, other)

    assert has_element?(view, "#preview-unconfigured")
    refute has_element?(view, "#preview-start-btn")
  end

  test "a start refused by the server says why on the page", %{conn: conn} = ctx do
    {_ws, issue} = setup_ticket(ctx, "perl #{ctx.script}")
    File.rm_rf!(issue |> BranchNamer.derive() |> Worktree.worktree_path())
    GitFixture.git!(ctx.clone, ["worktree", "prune"])
    view = mount_task(conn, issue)

    view |> element("#preview-start-btn") |> render_click()
    eventually(view, "#preview-start-error")
    assert render(view) =~ "no checkout to preview"
    settle(view)
  end

  test "the global list on /workers shows running previews with a Stop button",
       %{conn: conn} = ctx do
    {_ws, issue} = setup_ticket(ctx, "perl #{ctx.script}")
    {:ok, view, _html} = live(conn, ~p"/workers")
    refute has_element?(view, "#panel-previews")

    assert {:ok, %{status: "running"}} = Preview.start(issue.id, wait: true, timeout: 30_000)
    eventually(view, "#panel-previews")
    assert has_element?(view, "#preview-row-app-#{issue.id}")

    view |> element("#preview-stop-app-#{issue.id}") |> render_click()
    eventually(view, "#panel-previews", 0) |> then(fn _ -> :ok end) |> then(fn _ -> :ok end)
    gone(view, "#panel-previews")
    assert Preview.list() == []
    settle(view)
  end

  defp gone(view, selector, tries \\ 100) do
    cond do
      not has_element?(view, selector) -> :ok
      tries == 0 -> flunk("#{selector} never went away")
      true -> Process.sleep(100) && gone(view, selector, tries - 1)
    end
  end
end

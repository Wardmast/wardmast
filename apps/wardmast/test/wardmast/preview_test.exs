defmodule Wardmast.PreviewTest do
  # Real processes, real git, real sockets: a tiny perl HTTP server stands in
  # for the repo's app so the whole start -> ready -> stop path runs for real.
  use Wardmast.DataCase, async: false

  alias Wardmast.Nodes
  alias Wardmast.Preview
  alias Wardmast.Preview.Leases
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.GitFixture
  alias Wardmast.Worker.BranchNamer
  alias Wardmast.Workers.Run

  @server ~S"""
  use IO::Socket::INET; use Cwd; $| = 1;
  my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $ENV{PORT},
    Listen => 5, ReuseAddr => 1) or die "bind: $!";
  print "listening on $ENV{PORT}\n";
  while (my $c = $s->accept) {
    my $req = <$c>;
    my $body = getcwd() . " PORT=$ENV{PORT} DB=" . ($ENV{DB} // '') . " APP_PORT=" . ($ENV{APP_PORT} // '') . "\n";
    print $c "HTTP/1.0 200 OK\r\nContent-Length: " . length($body) . "\r\n\r\n$body";
    close $c;
  }
  """

  setup do
    fx = GitFixture.origin_and_clone()
    root = fx.root

    prior =
      for key <- [:preview_root, :worktree_root], do: {key, Application.get_env(:wardmast, key)}

    Application.put_env(:wardmast, :preview_root, Path.join(root, "previews"))
    Application.put_env(:wardmast, :worktree_root, Path.join(root, "worktrees"))

    on_exit(fn ->
      Enum.each(Preview.list(), &Preview.stop(&1.task_id))
      Enum.each(prior, fn {k, v} -> restore(k, v) end)
    end)

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    script = Path.join(bin, "server.pl")
    File.write!(script, @server)

    base = 31_000 + rem(System.unique_integer([:positive]), 90) * 10

    {:ok, Map.merge(fx, %{script: script, bin: bin, range: {base, base + 9}})}
  end

  defp restore(key, nil), do: Application.delete_env(:wardmast, key)
  defp restore(key, value), do: Application.put_env(:wardmast, key, value)

  defp preview_cfg(ctx, extra \\ %{}) do
    {lo, hi} = ctx.range

    Map.merge(
      %{
        "command" => "perl #{ctx.script}",
        "ready_timeout" => 20,
        "port_range" => "#{lo}-#{hi}",
        "env" => %{"DB" => "/tmp/preview-{{task_id}}.sqlite3"}
      },
      extra
    )
  end

  defp workspace!(ctx, cfg) do
    Ash.create!(Workspace, %{
      name: "preview-ws-#{System.unique_integer([:positive])}",
      config: %{
        "repo_paths" => %{"app" => ctx.clone, "other" => ctx.clone},
        "worker" => %{"repos" => %{"app" => %{"preview" => cfg}, "other" => %{"preview" => cfg}}}
      }
    })
  end

  defp ticket!(ws, repo \\ "app") do
    Ash.create!(Issue, %{
      title: "preview me #{System.unique_integer([:positive])}",
      workspace_id: ws.id,
      repo: repo
    })
  end

  defp worktree!(ctx, issue) do
    branch = BranchNamer.derive(issue)
    path = Wardmast.Worker.Worktree.worktree_path(branch)
    File.mkdir_p!(Path.dirname(path))
    GitFixture.git!(ctx.clone, ["worktree", "add", "-q", "-b", branch, path])
    {branch, path}
  end

  defp body(port), do: Req.get!("http://127.0.0.1:#{port}/", retry: false).body

  defp alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != "" and not String.starts_with?(String.trim(out), "Z")
      _ -> false
    end
  end

  describe "start/2 and stop/2" do
    test "runs the command in the ticket's worktree on a leased port, then stop frees everything",
         ctx do
      ws =
        workspace!(
          ctx,
          preview_cfg(ctx, %{
            "command" =>
              "sleep 300 & echo $! > #{ctx.bin}/sleep.pid; echo $$ > #{ctx.bin}/sh.pid; exec perl #{ctx.script}"
          })
        )

      issue = ticket!(ws)
      {_branch, wt} = worktree!(ctx, issue)

      assert {:ok, row} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert row.status == "running", inspect(row)
      assert row.checkout_kind == "worktree"
      assert row.checkout_path == wt
      {lo, hi} = ctx.range
      assert row.port in lo..hi
      assert row.url == "http://127.0.0.1:#{row.port}/"

      # port_env, templated env and cwd all reached the app
      served = body(row.port)
      assert served =~ wt
      assert served =~ "PORT=#{row.port}"
      assert served =~ "DB=/tmp/preview-#{issue.id}.sqlite3"

      assert row.port in Leases.held_ports()

      sleep_pid =
        ctx.bin |> Path.join("sleep.pid") |> File.read!() |> String.trim() |> String.to_integer()

      sh_pid =
        ctx.bin |> Path.join("sh.pid") |> File.read!() |> String.trim() |> String.to_integer()

      assert alive?(sleep_pid) and alive?(sh_pid)

      assert {:ok, [_]} = Preview.stop(issue.id)

      # the whole process group went, the lease is released, the port is free
      refute alive?(sh_pid)
      refute alive?(sleep_pid)
      assert Leases.get("app", issue.id) == nil
      refute row.port in Leases.held_ports()
      assert Leases.port_free?(row.port)
      assert {:error, :not_found} = Preview.stop(issue.id)
    end

    test "start on a running preview returns it instead of starting a second", ctx do
      ws = workspace!(ctx, preview_cfg(ctx))
      issue = ticket!(ws)
      worktree!(ctx, issue)

      assert {:ok, a} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert {:ok, b} = Preview.start(issue.id)
      assert b.port == a.port
      assert length(Preview.list()) == 1
    end

    test "concurrent previews — two tickets of a repo, and another repo — get distinct ports",
         ctx do
      ws = workspace!(ctx, preview_cfg(ctx))
      {t1, t2, t3} = {ticket!(ws), ticket!(ws), ticket!(ws, "other")}
      Enum.each([t1, t2, t3], &worktree!(ctx, &1))

      rows =
        for t <- [t1, t2, t3] do
          assert {:ok, row} = Preview.start(t.id, wait: true, timeout: 30_000)
          assert row.status == "running", inspect(row)
          row
        end

      ports = Enum.map(rows, & &1.port)
      assert length(Enum.uniq(ports)) == 3
      server = Leases.server_ports()
      {wlo, whi} = Wardmast.Preview.Config.worker_range()
      assert Enum.all?(ports, &(&1 not in server and &1 not in wlo..whi))
      assert Enum.all?(ports, fn p -> body(p) =~ "PORT=#{p}" end)
    end

    test "port_env names the variable, and {{port}} substitutes into the command", ctx do
      cfg =
        preview_cfg(ctx, %{
          "command" => "PORT={{port}} perl #{ctx.script}",
          "port_env" => "APP_PORT"
        })

      ws = workspace!(ctx, cfg)
      issue = ticket!(ws)
      worktree!(ctx, issue)
      assert {:ok, row} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert row.status == "running", inspect(row)
      served = body(row.port)
      assert served =~ "PORT=#{row.port}"
      assert served =~ "APP_PORT=#{row.port}"
    end

    test "runs setup once per preview directory", ctx do
      counter = Path.join(ctx.bin, "setup.count")
      ws = workspace!(ctx, preview_cfg(ctx, %{"setup" => "echo ran >> #{counter}"}))
      issue = ticket!(ws)
      worktree!(ctx, issue)

      assert {:ok, %{status: "running"}} = Preview.start(issue.id, wait: true, timeout: 30_000)
      {:ok, _} = Preview.stop(issue.id)
      assert {:ok, %{status: "running"}} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert counter |> File.read!() |> String.split("\n", trim: true) |> length() == 1
    end

    test "a failing setup fails the preview and releases the port", ctx do
      ws = workspace!(ctx, preview_cfg(ctx, %{"setup" => "echo boom; exit 4"}))
      issue = ticket!(ws)
      worktree!(ctx, issue)

      assert {:ok, row} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert row.status == "failed"
      assert row.error =~ "setup exited with status 4"
      assert row.port == nil
      assert Leases.held_ports() == []
      assert {:ok, %{content: log}} = Preview.logs(issue.id)
      assert log =~ "boom"
    end

    test "a command that exits fails with its status and the log is kept", ctx do
      ws = workspace!(ctx, preview_cfg(ctx, %{"command" => "echo crashed; exit 3"}))
      issue = ticket!(ws)
      worktree!(ctx, issue)

      assert {:ok, row} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert row.status == "failed"
      assert row.error =~ "status 3"
      assert {:ok, %{content: log}} = Preview.logs(issue.id)
      assert log =~ "crashed"
      # a failed row is replaced by the next start
      assert {:ok, again} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert again.status == "failed"
      assert length(Preview.list()) == 1
    end

    test "never ready within ready_timeout fails and kills the process", ctx do
      ws =
        workspace!(
          ctx,
          preview_cfg(ctx, %{
            "command" => "echo $$ > #{ctx.bin}/p.pid; exec sleep 300",
            "ready_timeout" => 2
          })
        )

      issue = ticket!(ws)
      worktree!(ctx, issue)
      assert {:ok, row} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert row.status == "failed"
      assert row.error =~ "not ready after 2s"
      pid = ctx.bin |> Path.join("p.pid") |> File.read!() |> String.trim() |> String.to_integer()
      refute alive?(pid)
      assert row.port == nil
    end

    test "refuses a repo with no preview config, and an unknown ticket", ctx do
      ws =
        Ash.create!(Workspace, %{
          name: "no-preview-#{System.unique_integer([:positive])}",
          config: %{"repo_paths" => %{"app" => ctx.clone}}
        })

      issue = ticket!(ws)
      assert {:error, {:not_configured, "app"}} = Preview.start(issue.id)
      assert {:error, :ticket_not_found} = Preview.start("bd-nope")
    end

    test "logs follow by offset", ctx do
      ws = workspace!(ctx, preview_cfg(ctx))
      issue = ticket!(ws)
      worktree!(ctx, issue)
      assert {:ok, %{status: "running"}} = Preview.start(issue.id, wait: true, timeout: 30_000)

      assert {:ok, %{content: first, offset: off}} = Preview.logs(issue.id)
      assert first =~ "listening on"
      assert {:ok, %{content: "", offset: ^off}} = Preview.logs(issue.id, offset: off)
    end
  end

  describe "checkout selection never touches a worker's checkout" do
    test "a live worker gets a separate snapshot of its HEAD", ctx do
      ws = workspace!(ctx, preview_cfg(ctx))
      issue = ticket!(ws)
      {_branch, wt} = worktree!(ctx, issue)
      GitFixture.commit!(wt, %{"committed.txt" => "yes\n"}, "work")
      File.write!(Path.join(wt, "wip.txt"), "uncommitted\n")

      head_before = GitFixture.git!(wt, ["rev-parse", "HEAD"])
      status_before = GitFixture.git!(wt, ["status", "--porcelain"])

      # a live worker for the ticket
      {:ok, _} = Registry.register(Wardmast.Worker.Registry, issue.id, nil)

      assert {:ok, row} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert row.status == "running", inspect(row)
      assert row.checkout_kind == "snapshot"
      assert row.checkout_path != wt
      assert row.checkout_note =~ "worker is live"
      assert File.exists?(Path.join(row.checkout_path, "committed.txt"))
      refute File.exists?(Path.join(row.checkout_path, "wip.txt"))
      assert body(row.port) =~ row.checkout_path
      # no push path from a preview checkout
      assert {_, 0} =
               System.cmd("git", ["-C", row.checkout_path, "remote"], stderr_to_stdout: true)

      assert GitFixture.git!(row.checkout_path, ["remote"]) == ""

      # the worker's tree is exactly as it was
      assert GitFixture.git!(wt, ["rev-parse", "HEAD"]) == head_before
      assert GitFixture.git!(wt, ["status", "--porcelain"]) == status_before
      assert File.read!(Path.join(wt, "wip.txt")) == "uncommitted\n"
    end

    test "a ticket whose run is on a cluster node previews the pushed head on the primary", ctx do
      ws = workspace!(ctx, preview_cfg(ctx))
      issue = ticket!(ws)
      branch = BranchNamer.derive(issue)

      # the pushed head: committed elsewhere, only on origin
      GitFixture.git!(ctx.clone, ["checkout", "-q", "-b", branch])
      GitFixture.commit!(ctx.clone, %{"pushed.txt" => "on origin\n"}, "pushed work")
      GitFixture.git!(ctx.clone, ["push", "-q", "origin", branch])
      GitFixture.git!(ctx.clone, ["checkout", "-q", "main"])
      GitFixture.git!(ctx.clone, ["branch", "-q", "-D", branch])

      {:ok, %{token: t}} = Nodes.mint_join_token([name: "pv-node"], "operator:test")
      {:ok, %{node: node}} = Nodes.redeem_join_token(t)

      Ash.create!(Run, %{
        task_id: issue.id,
        base_task_id: issue.id,
        repo: "app",
        kind: :implement,
        provider: "claude",
        state: :working,
        node_id: node.id,
        started_at: DateTime.utc_now()
      })

      assert {:ok, row} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert row.status == "running", inspect(row)
      assert row.checkout_kind == "remote_head"
      assert row.checkout_note =~ "Read-only"
      assert row.checkout_note =~ "cluster node"
      assert File.read!(Path.join(row.checkout_path, "pushed.txt")) == "on origin\n"
      assert GitFixture.git!(row.checkout_path, ["remote"]) == ""
    end

    test "no checkout anywhere is a clear error and leaks no lease", ctx do
      ws = workspace!(ctx, preview_cfg(ctx))
      issue = ticket!(ws)
      assert {:error, {:no_checkout, _}} = Preview.start(issue.id)
      assert Leases.list() == []
    end
  end

  describe "lifecycle" do
    test "closing the ticket stops its preview", ctx do
      ws = workspace!(ctx, preview_cfg(ctx))
      issue = ticket!(ws)
      worktree!(ctx, issue)

      assert {:ok, %{status: "running", port: port}} =
               Preview.start(issue.id, wait: true, timeout: 30_000)

      Wardmast.LifecycleFixtures.put_state!(issue, :closed)

      assert Leases.get("app", issue.id) == nil
      assert Leases.port_free?(port)
    end

    test "sweep stops a preview whose ticket closed behind the hook's back", ctx do
      ws = workspace!(ctx, preview_cfg(ctx))
      issue = ticket!(ws)
      worktree!(ctx, issue)

      assert {:ok, %{status: "running", port: port}} =
               Preview.start(issue.id, wait: true, timeout: 30_000)

      import Ecto.Query

      Wardmast.Repo.update_all(from(i in "issues", where: i.id == ^issue.id),
        set: [state: "closed"]
      )

      assert [{task_id, reason}] = Preview.sweep()
      assert task_id == issue.id
      assert reason =~ "closed or merged"
      assert Leases.get("app", issue.id) == nil
      assert Leases.port_free?(port)
    end

    test "sweep stops a preview whose worktree was removed", ctx do
      ws = workspace!(ctx, preview_cfg(ctx))
      issue = ticket!(ws)
      {_, wt} = worktree!(ctx, issue)
      assert {:ok, %{status: "running"}} = Preview.start(issue.id, wait: true, timeout: 30_000)
      assert Preview.sweep() == []

      File.rm_rf!(wt)
      assert [{_, reason}] = Preview.sweep()
      assert reason =~ "worktree was removed"
      assert Leases.get("app", issue.id) == nil
    end

    test "sweep stops an idle preview after idle_ttl_seconds, and only then", ctx do
      ws = workspace!(ctx, preview_cfg(ctx, %{"idle_ttl_seconds" => 60}))
      issue = ticket!(ws)
      worktree!(ctx, issue)
      assert {:ok, %{status: "running"}} = Preview.start(issue.id, wait: true, timeout: 30_000)

      assert Preview.sweep(DateTime.add(DateTime.utc_now(), 30, :second)) == []
      assert [{_, reason}] = Preview.sweep(DateTime.add(DateTime.utc_now(), 120, :second))
      assert reason =~ "idle"
      assert Leases.get("app", issue.id) == nil
    end

    test "touching a preview (reading it) resets its idle clock", ctx do
      ws = workspace!(ctx, preview_cfg(ctx, %{"idle_ttl_seconds" => 60}))
      issue = ticket!(ws)
      worktree!(ctx, issue)
      assert {:ok, %{status: "running"}} = Preview.start(issue.id, wait: true, timeout: 30_000)

      later = DateTime.add(DateTime.utc_now(), 50, :second)
      Leases.update(Leases.get("app", issue.id), %{touched_at: later})
      assert Preview.sweep(DateTime.add(later, 30, :second)) == []
    end

    test "sweep fails a row whose process is gone (a restart orphaned it) and frees its port",
         ctx do
      {:ok, lease} =
        Leases.acquire(%{repo: "app", task_id: "bd-orphan", workspace_id: nil}, ctx.range)

      {:ok, _} = Leases.update(lease, %{status: "running"})

      assert [{"bd-orphan", "orphaned"}] = Preview.sweep()
      row = Leases.get("app", "bd-orphan")
      assert row.status == "failed"
      assert row.port == nil
    end
  end
end

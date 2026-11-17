defmodule Wardmast.Worker.DispatchAutoBackendTest do
  @moduledoc """
  `sandbox.backend: auto` (bd-56z2wz) through `Worker.Dispatch.dispatch/2`: placement
  decides first, then the run gets the backend and checkout layout that machine means,
  and an existing checkout's layout is never changed.
  """
  use Wardmast.DataCase, async: false

  require Ash.Query

  alias Wardmast.Agents.SecurityPolicy
  alias Wardmast.Nodes
  alias Wardmast.Nodes.Placement
  alias Wardmast.Settings
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.ResumeSlotFixture
  alias Wardmast.Worker
  alias Wardmast.Worker.BranchNamer
  alias Wardmast.Worker.Dispatch
  alias Wardmast.Worker.GitLayout
  alias Wardmast.Worker.PrivateClone
  alias Wardmast.Worker.Worktree

  @repo ResumeSlotFixture.repo()
  @auto [security: %{"sandbox" => %{"backend" => "auto"}}]

  setup do
    sandbox = ResumeSlotFixture.setup_repo!()
    ResumeSlotFixture.put_local_cap(nil)
    on_exit(fn -> Settings.set_nodes_local_max_workers(nil) end)

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true,
          worker_deps_cache: false
        ],
        do: put_app_env(:wardmast, key, value)

    %{sandbox: sandbox}
  end

  defp workspace!(mode) do
    n = System.unique_integer([:positive])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "auto-#{n}",
        prefix: "au#{n}",
        config: %{"worker" => %{"placement" => mode}}
      })

    ws
  end

  defp ready!(ws, title) do
    {:ok, created} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- auto fixture"})

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    issue
  end

  defp active!(ws, title) do
    {:ok, active} = Ash.update(ready!(ws, title), %{}, action: :start)
    active
  end

  defp node_row(attrs \\ []) do
    Map.merge(
      %{
        id: "n-auto",
        name: "mesaana",
        state: :online,
        health: :ready,
        max: 2,
        live: 0,
        workspace_ids: [],
        labels: [],
        caps: %{}
      },
      Map.new(attrs)
    )
  end

  defp full_node, do: node_row(live: 2)

  # The agent spawn, captured: the node the run went to and the policy it was handed.
  defp capture_spawn do
    test = self()

    fn session_opts ->
      send(test, {:spawned, Keyword.get(session_opts, :node), session_opts[:security]})
      {:ok, :captured}
    end
  end

  defp dispatch(issue, nodes, extra \\ []) do
    Dispatch.dispatch(
      issue.id,
      Keyword.merge(
        @auto ++
          [repo: @repo, start_driver: false, nodes: nodes, start_claude: true] ++
          [claude_start: capture_spawn()],
        extra
      )
    )
  end

  defp stop(issue, pid) do
    ref = Process.monitor(pid)
    :ok = Worker.stop(issue.id, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
  end

  defp checkout_path(issue), do: issue |> BranchNamer.derive() |> Worktree.worktree_path()

  defp decision(issue) do
    Wardmast.Workers.Run
    |> Ash.Query.filter(base_task_id == ^issue.id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> Map.fetch!(:routing_decision)
  end

  describe "a fresh run" do
    test "(a) with a free node slot goes to the node as podman on a private clone" do
      issue = ready!(workspace!("prefer_remote"), "auto node")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [node_row()])
      assert_receive {:spawned, %{id: "n-auto"}, policy}
      assert SecurityPolicy.sandbox_backend(policy) == :podman
      refute SecurityPolicy.auto?(policy)

      assert GitLayout.existing(checkout_path(issue)) == :private_clone
      assert PrivateClone.clone?(checkout_path(issue))

      assert %{"placement" => %{"sandbox_backend" => "auto: mesaana had a free slot -> podman"}} =
               decision(issue)

      stop(issue, pid)
    end

    test "(b) with no node slot and a free local slot it runs locally on bwrap with a linked worktree" do
      issue = ready!(workspace!("prefer_remote"), "auto local")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [full_node()])
      assert_receive {:spawned, nil, policy}
      assert policy == nil, "bwrap is the unsandboxed-by-session path: no container policy"

      assert GitLayout.existing(checkout_path(issue)) == :linked_worktree

      assert %{"placement" => %{"sandbox_backend" => "auto: no node slot -> local bwrap"}} =
               decision(issue)

      stop(issue, pid)
    end

    test "the local backend is configurable: local_backend podman runs the primary's side in a container" do
      issue = ready!(workspace!("prefer_remote"), "auto local podman")

      opts = [security: %{"sandbox" => %{"backend" => "auto", "local_backend" => "podman"}}]
      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [full_node()], opts)
      assert_receive {:spawned, nil, policy}
      assert SecurityPolicy.sandbox_backend(policy) == :podman
      assert GitLayout.existing(checkout_path(issue)) == :private_clone

      assert decision(issue)["placement"]["sandbox_backend"] ==
               "auto: no node slot -> local podman"

      stop(issue, pid)
    end

    test "(c) with neither it is held naming both sides, and nothing is created" do
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)
      issue = ready!(workspace!("prefer_remote"), "auto held")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, [full_node()])
      assert info.phrase =~ "held — local capacity 0"
      assert info.phrase =~ "auto: no node had a free slot"
      assert info.phrase =~ "local bwrap has no slot"

      assert Worker.whereis(issue.id) == nil
      assert Ash.get!(Issue, issue.id).state == :queued
      refute File.exists?(checkout_path(issue))
      assert Placement.reservations() == []
    end

    test "(d) an agy run under auto runs locally on bwrap and is never refused for the backend" do
      issue = ready!(workspace!("prefer_remote"), "auto agy")

      assert {:ok, %{worker_pid: pid}} =
               dispatch(issue, [node_row()], agent_type: :gemini, start_claude: false)

      assert Placement.reservations() == []
      assert GitLayout.existing(checkout_path(issue)) == :linked_worktree

      assert %{"placement" => %{"sandbox_backend" => phrase}} = decision(issue)
      assert phrase =~ "no container wrap point -> local bwrap"
      stop(issue, pid)
    end

    test "worker.placement local_only keeps auto on the primary, bwrap" do
      issue = ready!(workspace!("local_only"), "auto local only")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [node_row()])
      assert_receive {:spawned, nil, policy}
      assert policy == nil, "bwrap is the unsandboxed-by-session path: no container policy"
      assert GitLayout.existing(checkout_path(issue)) == :linked_worktree
      stop(issue, pid)
    end

    test "remote_only never uses the primary, and holds when no node has a slot" do
      issue = ready!(workspace!("remote_only"), "auto remote only")
      assert {:error, {:no_node_capacity, info}} = dispatch(issue, [full_node()])
      assert info.mode == :remote_only
      assert Worker.whereis(issue.id) == nil
    end
  end

  describe "prefer_local and prefer_remote ordering" do
    test "prefer_local runs on the primary while it has room, even with a free node" do
      issue = ready!(workspace!("prefer_local"), "prefer local")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [node_row()])
      assert_receive {:spawned, nil, policy}
      assert policy == nil, "bwrap is the unsandboxed-by-session path: no container policy"
      assert decision(issue)["placement"]["sandbox_backend"] =~ "prefer_local"
      assert decision(issue)["placement"]["sandbox_backend"] =~ "local bwrap"
      stop(issue, pid)
    end

    test "prefer_local overflows to the node only when the primary is full" do
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)
      issue = ready!(workspace!("prefer_local"), "prefer local overflow")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [node_row()])
      assert_receive {:spawned, %{id: "n-auto"}, policy}
      assert SecurityPolicy.sandbox_backend(policy) == :podman
      stop(issue, pid)
    end

    test "prefer_remote takes the node first, the primary when it is full" do
      issue = ready!(workspace!("prefer_remote"), "prefer remote first")
      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [node_row()])
      assert_receive {:spawned, %{id: "n-auto"}, _}
      stop(issue, pid)
    end
  end

  describe "a ticket whose checkout already exists keeps its layout (bd-1h0zhg)" do
    defp resume_opts, do: [resume: true]

    test "a preserved linked worktree resumes locally on bwrap even with a free node", %{
      sandbox: sandbox
    } do
      issue = active!(workspace!("prefer_remote"), "resume linked")
      branch = BranchNamer.derive(issue)
      {:ok, path} = Worktree.create(sandbox.repo, branch, "main", layout: :linked_worktree)

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [node_row()], resume_opts())
      assert_receive {:spawned, nil, policy}
      assert policy == nil, "bwrap is the unsandboxed-by-session path: no container policy"
      assert GitLayout.existing(path) == :linked_worktree

      assert decision(issue)["placement"]["sandbox_backend"] =~
               "already a linked worktree on the primary -> local bwrap"

      stop(issue, pid)
    end

    test "a linked worktree with unpushed commits resumes locally on it", %{sandbox: sandbox} do
      issue = active!(workspace!("prefer_remote"), "resume unpushed")
      branch = BranchNamer.derive(issue)
      {:ok, path} = Worktree.create(sandbox.repo, branch, "main", layout: :linked_worktree)
      File.write!(Path.join(path, "work.txt"), "work")
      {_, 0} = System.cmd("git", ["add", "-A"], cd: path)
      {_, 0} = System.cmd("git", ["commit", "-qm", "local only"], cd: path)

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [node_row()], resume_opts())
      assert_receive {:spawned, nil, policy}
      assert policy == nil, "bwrap is the unsandboxed-by-session path: no container policy"
      assert GitLayout.existing(path) == :linked_worktree
      stop(issue, pid)
    end

    test "a private clone resumes as one on a node when a slot is free", %{sandbox: sandbox} do
      issue = active!(workspace!("prefer_remote"), "resume clone node")
      branch = BranchNamer.derive(issue)
      {:ok, path} = Worktree.create(sandbox.repo, branch, "main", layout: :private_clone)

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [node_row()], resume_opts())
      assert_receive {:spawned, %{id: "n-auto"}, policy}
      assert SecurityPolicy.sandbox_backend(policy) == :podman
      assert GitLayout.existing(path) == :private_clone
      stop(issue, pid)
    end

    test "a private clone resumes as a container on the primary when no node has a slot",
         %{sandbox: sandbox} do
      issue = active!(workspace!("prefer_remote"), "resume clone local")
      branch = BranchNamer.derive(issue)
      {:ok, path} = Worktree.create(sandbox.repo, branch, "main", layout: :private_clone)

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, [full_node()], resume_opts())
      assert_receive {:spawned, nil, policy}
      assert SecurityPolicy.sandbox_backend(policy) == :podman
      assert GitLayout.existing(path) == :private_clone

      assert decision(issue)["placement"]["sandbox_backend"] ==
               "auto: no node slot, its checkout is a private clone -> local podman"

      stop(issue, pid)
    end

    test "an agy run on a ticket whose checkout is a private clone is held, not mixed in",
         %{sandbox: sandbox} do
      issue = active!(workspace!("prefer_remote"), "resume clone agy")
      branch = BranchNamer.derive(issue)
      {:ok, path} = Worktree.create(sandbox.repo, branch, "main", layout: :private_clone)

      assert {:error, {:sandbox_backend, _provider, "held — " <> detail}} =
               dispatch(
                 issue,
                 [full_node()],
                 [agent_type: :gemini, start_claude: false] ++ resume_opts()
               )

      assert detail =~ "podman"
      assert GitLayout.existing(path) == :private_clone
      assert Placement.reservations() == []
    end
  end
end

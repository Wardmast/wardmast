defmodule Wardmast.Nodes.AutoBackendPlacementTest do
  @moduledoc """
  `sandbox.backend: auto` (bd-56z2wz): placement decides first. A node is podman on a
  private clone; the primary is its local backend (bwrap by default) on a linked
  worktree. A run is held only when neither side has a slot.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Nodes.LocalCapacity
  alias Wardmast.Nodes.Placement

  defp cnode(name, attrs \\ []) do
    Map.merge(
      %{
        id: "node-" <> name,
        name: name,
        state: :online,
        health: :ready,
        labels: [],
        workspace_ids: [],
        live: 0,
        max: 2
      },
      Map.new(attrs)
    )
  end

  defp request(attrs \\ []) do
    Map.merge(
      %{
        task_id: "bd-auto-#{System.unique_integer([:positive])}",
        workspace_id: "ws",
        kind: :implementer,
        provider: :claude,
        layout: :private_clone,
        auto?: true,
        local_backend: :bwrap,
        existing_layout: nil,
        mode: :prefer_remote
      },
      Map.new(attrs)
    )
  end

  defp gate(req, nodes),
    do: LocalCapacity.gate_with_reason(req, nodes: nodes, remote_available?: true)

  setup do
    on_exit(fn -> Wardmast.Settings.set_nodes_local_max_workers(nil) end)
    {:ok, 3} = Wardmast.Nodes.set_local_max_workers(3, nil)
    :ok
  end

  describe "eligible/1 under auto" do
    test "a Claude implementer is a candidate for a node whatever its layout was resolved to" do
      assert Placement.eligible(request()) == :ok
      assert Placement.eligible(request(provider: :codex)) == :ok
    end

    # bd-b2t0kw: agy's container signs in with the workspace's service-account key (it has
    # no keyring); a workspace without one keeps agy local, on bwrap, never refused.
    test "agy without the workspace's service-account key stays local: never refused, never a node" do
      for provider <- [:gemini, "gemini", :antigravity] do
        assert {:local_only, :no_agy_credential} =
                 Placement.eligible(request(provider: provider))

        assert {:local_only, :no_agy_credential} =
                 Placement.eligible(request(provider: provider, agy_credential?: false))
      end

      assert Placement.reason_phrase(:no_agy_credential, %{provider: :gemini}) =~
               "service-account key"

      assert Placement.local_backend(request(provider: :gemini, local_backend: :podman)) == :bwrap
    end

    test "agy with the workspace's service-account key has a container: a node candidate" do
      req = request(provider: :gemini, agy_credential?: true)
      assert Placement.eligible(req) == :ok
      assert Placement.container_capable?(req)
      refute Placement.container_capable?(request(provider: :gemini))
      assert Placement.container_capable?(request(provider: :claude))
      refute Placement.container_capable?(request(provider: :grok))

      assert Placement.local_backend(%{req | local_backend: :podman}) == :podman
      assert Placement.local_backend(req) == :bwrap
    end

    test "a ticket with a preserved linked worktree stays local, on its original layout" do
      assert {:local_only, :existing_linked_worktree} =
               Placement.eligible(request(existing_layout: :linked_worktree))

      assert Placement.eligible(request(existing_layout: :private_clone)) == :ok
    end

    test "unpushed commits and uncommitted work keep it local, as for podman" do
      assert {:local_only, :unpushed_commits} = Placement.eligible(request(unpushed?: true))
      assert {:local_only, :local_work} = Placement.eligible(request(local_work?: true))
    end

    test "worker.placement local_only keeps it local" do
      assert {:local_only, :placement_local_only} = Placement.eligible(request(mode: :local_only))
    end

    test "a non-auto bwrap run is still :not_podman" do
      assert {:local_only, :not_podman} =
               Placement.eligible(request(auto?: false, layout: :linked_worktree))
    end
  end

  describe "gate under auto (acceptance a-d)" do
    test "(a) a Claude run with a free node slot is placed on the node" do
      req = request()
      assert {:ok, {:node, %{name: "mesaana"}}} = gate(req, [cnode("mesaana")])
      Placement.release(req.task_id)
    end

    test "(b) with no free node slot and a free local slot it runs locally" do
      req = request()
      assert {:ok, :local, :no_node} = gate(req, [cnode("mesaana", live: 2)])
      Placement.release(req.task_id)
    end

    test "(c) with neither it is held, naming both sides" do
      {:ok, 0} = Wardmast.Nodes.set_local_max_workers(0, nil)

      assert {:error, {:no_node_capacity, info}} = gate(request(), [cnode("mesaana", live: 2)])
      assert info.phrase =~ "held — local capacity 0"
      assert info.phrase =~ "auto: no node had a free slot"
      assert info.phrase =~ "local bwrap has no slot"
    end

    test "(d) an agy run without a key is local on bwrap and is not held for the backend" do
      req = request(provider: :gemini)
      assert {:ok, :local, {:local_only, :no_agy_credential}} = gate(req, [cnode("mesaana")])
      Placement.release(req.task_id)
    end

    test "(d) an agy run held at a full primary names why it could not use a node" do
      {:ok, 0} = Wardmast.Nodes.set_local_max_workers(0, nil)
      assert {:error, {:no_node_capacity, info}} = gate(request(provider: :gemini), [cnode("m")])
      assert info.phrase =~ "agy" or info.phrase =~ "gemini"
      assert info.phrase =~ "service-account key"
      assert info.phrase =~ "local bwrap has no slot"
    end

    test "the held phrase names the configured local backend" do
      {:ok, 0} = Wardmast.Nodes.set_local_max_workers(0, nil)

      assert {:error, {:no_node_capacity, info}} =
               gate(request(local_backend: :podman), [cnode("mesaana", live: 2)])

      assert info.phrase =~ "local podman has no slot"
    end
  end

  describe "worker.placement ordering under auto" do
    test "prefer_remote takes a node with a slot even when the primary is free" do
      req = request(mode: :prefer_remote)
      assert {:ok, {:node, %{name: "a"}}} = gate(req, [cnode("a")])
      Placement.release(req.task_id)
    end

    test "prefer_local uses the primary while it has a slot, leaving the node free" do
      req = request(mode: :prefer_local)
      assert {:ok, :local, :prefer_local} = gate(req, [cnode("a")])
      Placement.release(req.task_id)
    end

    test "prefer_local overflows to a node only when the primary is full" do
      {:ok, 0} = Wardmast.Nodes.set_local_max_workers(0, nil)
      req = request(mode: :prefer_local)
      assert {:ok, {:node, %{name: "a"}}} = gate(req, [cnode("a")])
      Placement.release(req.task_id)
    end

    test "prefer_local with both full is held, naming both" do
      {:ok, 0} = Wardmast.Nodes.set_local_max_workers(0, nil)
      req = request(mode: :prefer_local)
      assert {:error, {:no_node_capacity, info}} = gate(req, [cnode("a", live: 2)])
      assert info.phrase =~ "auto: no node had a free slot"
    end

    test "prefer_local on a run that must stay local does not look at nodes" do
      req = request(mode: :prefer_local, provider: :gemini)
      assert {:ok, :local, _} = gate(req, [cnode("a")])
      Placement.release(req.task_id)
    end

    test "prefer_local works for a plain podman run too" do
      {:ok, 0} = Wardmast.Nodes.set_local_max_workers(0, nil)
      req = request(auto?: false, mode: :prefer_local)
      assert {:ok, {:node, _}} = gate(req, [cnode("a")])
      Placement.release(req.task_id)
    end

    test "remote_only never falls back to the primary, even under auto" do
      assert {:error, {:no_node_capacity, %{mode: :remote_only}}} =
               gate(request(mode: :remote_only), [cnode("a", live: 2)])
    end

    test "local_only never leaves the primary" do
      assert {:ok, :local, {:local_only, :placement_local_only}} =
               gate(request(mode: :local_only), [cnode("a")])
    end

    test "mode/1 reads prefer_local" do
      assert Placement.mode(%{config: %{"worker" => %{"placement" => "prefer_local"}}}) ==
               :prefer_local
    end
  end

  describe "backend_phrase/2 (what the run records)" do
    test "a node run says which node had the slot and that it is podman" do
      assert Placement.backend_phrase(request(), {:node, %{name: "mesaana"}}) ==
               "auto: mesaana had a free slot -> podman"
    end

    test "a local run says why and which local backend" do
      assert Placement.backend_phrase(request(), {:local, :no_node}) ==
               "auto: no node slot -> local bwrap"

      assert Placement.backend_phrase(request(), {:local, :prefer_local}) ==
               "auto: prefer_local, the primary had a free slot -> local bwrap"

      assert Placement.backend_phrase(
               request(),
               {:local, {:local_only, :existing_linked_worktree}}
             ) =~
               "auto: its checkout is already a linked worktree on the primary -> local bwrap"

      assert Placement.backend_phrase(
               request(provider: :gemini),
               {:local, {:local_only, :no_agy_credential}}
             ) =~
               "service-account key -> local bwrap"

      assert Placement.backend_phrase(
               request(provider: :grok),
               {:local, {:local_only, :provider_no_container}}
             ) =~
               "no container wrap point -> local bwrap"
    end

    test "an existing private clone resumes as one" do
      assert Placement.backend_phrase(
               request(existing_layout: :private_clone),
               {:local, :no_node}
             ) == "auto: no node slot, its checkout is a private clone -> local podman"
    end
  end
end

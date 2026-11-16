defmodule Wardmast.NodeAgent.RoleBootTest do
  # Not async: starts supervision trees and flips process-wide application env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Wardmast.NodeAgent
  alias Wardmast.NodeAgent.Supervisor, as: AgentSupervisor

  # A stand-in for "a child somebody adds to the primary list later": it tells
  # the test it started.
  defmodule Probe do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    def init(test_pid) do
      send(test_pid, :primary_child_started)
      {:ok, test_pid}
    end
  end

  defp child_id(spec), do: Supervisor.child_spec(spec, []).id

  describe "role/0" do
    setup do
      previous = Application.fetch_env(:wardmast, :role)

      on_exit(fn ->
        case previous do
          {:ok, role} -> Application.put_env(:wardmast, :role, role)
          :error -> Application.delete_env(:wardmast, :role)
        end
      end)
    end

    test "defaults to :primary when nothing configured it" do
      Application.delete_env(:wardmast, :role)
      assert NodeAgent.role() == {:ok, :primary}
    end

    test "reads the configured role" do
      Application.put_env(:wardmast, :role, :agent)
      assert NodeAgent.role() == {:ok, :agent}
    end

    test "an unknown role is an error, never a primary" do
      for bogus <- [:agnet, "agent", nil, 1] do
        Application.put_env(:wardmast, :role, bogus)
        assert {:error, {:unknown_role, ^bogus}} = NodeAgent.role()
      end
    end
  end

  describe "Wardmast.Application.supervisor_children/2" do
    test "agent mode starts only the NodeAgent supervisor and never evaluates the primary list" do
      primary = fn -> flunk("the primary child list must not be built in agent mode") end

      assert {:ok, [spec]} = Wardmast.Application.supervisor_children(:agent, primary)
      assert child_id(spec) == AgentSupervisor
    end

    test "primary mode returns exactly the primary list" do
      assert {:ok, [Probe]} =
               Wardmast.Application.supervisor_children(:primary, fn -> [Probe] end)
    end

    test "an unknown role starts nothing" do
      assert {:error, {:unknown_role, :bogus}} =
               Wardmast.Application.supervisor_children(:bogus, fn -> [Probe] end)
    end
  end

  describe "a primary child added later" do
    test "does not start in agent mode" do
      test_pid = self()
      primary = fn -> [{Probe, test_pid}] end

      {:ok, children} = Wardmast.Application.supervisor_children(:agent, primary)

      sup =
        start_supervised!(%{
          id: :agent_tree,
          start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
          type: :supervisor
        })

      refute_received :primary_child_started
      ids = sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
      assert ids == [AgentSupervisor]
      refute Enum.any?(ids, &(&1 == Wardmast.Repo))
    end

    test "does start in primary mode (the probe really is a child that would run)" do
      test_pid = self()

      {:ok, children} =
        Wardmast.Application.supervisor_children(:primary, fn -> [{Probe, test_pid}] end)

      start_supervised!(%{
        id: :primary_tree,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
        type: :supervisor
      })

      assert_received :primary_child_started
    end
  end
end

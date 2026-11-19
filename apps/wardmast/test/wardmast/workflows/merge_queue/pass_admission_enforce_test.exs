defmodule Wardmast.Workflows.MergeQueue.PassAdmissionEnforceTest do
  @moduledoc """
  A CI fix or conflict pass for a ticket in Merging under seat
  admission (DC8, design `provider-dynamic-concurrency.md` §2.2, §3.2, I9). The pass is a follow-up of in-flight work (an open PR): it is
  counted on the pool it runs on and never held for a full layer, so it starts
  at once. A cap of 0 on the primary still holds it.
  """
  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Wardmast.Nodes
  alias Wardmast.Settings
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker.Registry, as: WorkerRegistry
  alias Wardmast.Workflows.MergeQueue.PassAdmission

  setup do
    on_exit(fn -> Settings.set_nodes_local_max_workers(nil) end)

    ws =
      Ash.create!(Workspace, %{
        name: "pae-#{System.unique_integer([:positive])}",
        prefix: "pae#{System.unique_integer([:positive])}"
      })

    # The board's cap is the primary's 1, and another ticket In progress holds
    # it. Its live worker also holds the one seat of the claude account's pool
    # (`max_concurrent: 1`), so the pool is full too.
    {:ok, 1} = Nodes.set_local_max_workers(1, nil)

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "pae-#{System.unique_integer([:positive])}",
        max_concurrent: 1
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    holding =
      Ash.create!(Issue, %{title: "holding the slot", workspace_id: ws.id})
      |> put_state!(:active)

    live_worker!(holding.id, ws.id)

    task = Ash.create!(Issue, %{title: "red CI", workspace_id: ws.id}) |> put_state!(:merging)
    %{task: task}
  end

  # A live claude worker registered under `key`, as a running ticket's is.
  defp live_worker!(key, ws_id) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(WorkerRegistry, key, nil)
        :ok = WorkerRegistry.put_dispatch(key, ws_id, "claude", [])
        send(test, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp deferrer do
    test = self()

    fn task_id, kind, _opts ->
      send(test, {:deferred, task_id, kind})
      :ok
    end
  end

  for kind <- [:fix_pass, :conflict] do
    test "#{kind}, a follow-up, it starts at once", %{task: task} do
      assert :ok = PassAdmission.admit(task, unquote(kind), %{defer_resume: deferrer()})
      refute_received {:deferred, _, _}
    end

    test "#{kind}, a primary cap of 0 still holds it", %{task: task} do
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)

      assert {:error, {:no_node_capacity, %{cap: 0}}} =
               PassAdmission.admit(task, unquote(kind), %{defer_resume: deferrer()})
    end
  end
end

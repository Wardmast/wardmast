defmodule Wardmast.Board.SnapshotLoadWalkTest do
  @moduledoc """
  `Snapshot.load/1` (DC6, DC12) gathers the walk's inputs
  (`Wardmast.Board.WalkInputs`) and plans the walk: its entries are the board's
  Ready column. A walk whose inputs cannot be read is planned with no capacity
  sets, so nothing is placed and every free card waits for capacity.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Wardmast.Board.Snapshot
  alias Wardmast.Quota.Budget
  alias Wardmast.Tasks.{Issue, Workspace}

  setup do
    ws =
      Ash.create!(Workspace, %{
        name: "load-walk-#{System.unique_integer([:positive])}",
        prefix: "lw#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "lw-#{System.unique_integer([:positive])}",
        max_concurrent: 3
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    created =
      Ash.create!(Issue, %{title: "ready", workspace_id: ws.id, acceptance: "- walk fixture"})

    ready = Ash.update!(created, %{}, action: :promote_to_ready)

    walk_opts = [
      budgets: [
        %Budget{
          account: account.id,
          pool: "claude",
          budget: 2,
          binding: {:window, "5h"},
          reason: "5h"
        }
      ],
      seats: %{},
      local: %{cap: 6, used: 0},
      remote_available?: false
    ]

    %{ws: ws, account: account, ready: ready, walk_opts: walk_opts}
  end

  test "the board carries the walk, and its entries are the Ready column", ctx do
    %{ws: ws, account: account, ready: ready, walk_opts: walk_opts} = ctx
    now = DateTime.utc_now()

    board = Snapshot.load(workspace_id: ws.id, now: now, walk_opts: walk_opts)

    assert Enum.map(board.ready, & &1.id) == [ready.id]

    assert %{promote: promote, placements: [%{pool: pool, node: "local"}]} = board.walk
    assert promote == ready.id
    assert pool == {account.id, "claude"}
    assert board.walk.pools[{account.id, "claude"}].budget == 2
  end

  # Seen live (v0.2.43): today's slot total full, the primary over its own cap
  # with review-side runs it never holds, and a node with room.
  test "the walk places a remote-eligible card on a node's free slot while the primary is full",
       ctx do
    remote_ws =
      Ash.create!(Workspace, %{
        name: "load-walk-remote-#{System.unique_integer([:positive])}",
        prefix: "lr#{System.unique_integer([:positive])}",
        config: %{
          "worker" => %{"placement" => "prefer_remote"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}
        }
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: remote_ws.id,
      provider: :claude,
      provider_account_id: ctx.account.id
    })

    remote =
      Ash.create!(Issue, %{title: "remote", workspace_id: remote_ws.id, acceptance: "- walk"})
      |> Ash.update!(%{}, action: :promote_to_ready)

    walk_opts =
      Keyword.merge(ctx.walk_opts,
        local: %{cap: 2, used: 4},
        remote_available?: true,
        nodes: [
          %{id: "oryx", name: "ryan-oryx-pro", state: :online, health: :ready, max: 3, live: 1}
        ]
      )

    now = DateTime.utc_now()
    opts = [workspace_id: remote_ws.id, now: now, slots_total: 0, walk_opts: walk_opts]

    board = Snapshot.load(opts)

    assert %{promote: promote, placements: [%{node: "oryx"}]} = board.walk
    assert promote == remote.id

    # The setup's ticket is local-only: it waits on the full primary.
    assert %{wait_cause: {:capacity, :node}, reason: local_reason} =
             Enum.find(board.walk.entries, &(&1.id == ctx.ready.id))

    assert local_reason =~ "local 4 of 2"
  end

  @tag capture_log: true
  test "a walk whose inputs cannot be read places nothing", ctx do
    board =
      Snapshot.load(
        workspace_id: ctx.ws.id,
        walk_opts: Keyword.put(ctx.walk_opts, :budgets, :not_a_list)
      )

    assert %{promote: nil, placements: []} = board.walk
    assert [%{id: id, state: :blocked}] = board.ready
    assert id == ctx.ready.id
  end

  @tag capture_log: true
  test "a walk input read that exits places nothing", ctx do
    # The node overview, read only for the walk, exiting as a dead process would.
    exiting = Stream.map([:row], fn _ -> exit(:node_overview_down) end)

    board =
      Snapshot.load(
        workspace_id: ctx.ws.id,
        walk_opts: Keyword.merge(ctx.walk_opts, remote_available?: true, nodes: exiting)
      )

    assert %{promote: nil, placements: []} = board.walk
    assert [%{id: id, state: :blocked}] = board.ready
    assert id == ctx.ready.id
  end
end

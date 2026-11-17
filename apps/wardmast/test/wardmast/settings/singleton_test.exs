defmodule Wardmast.Settings.SingletonTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.Repo
  alias Wardmast.Settings
  alias Wardmast.Settings.Installation

  defp count, do: Repo.query!("SELECT count(*) FROM installation_settings").rows |> hd() |> hd()

  test "the database refuses a second installation row" do
    assert {:ok, 4} = Settings.set_nodes_local_max_workers(4)
    assert count() == 1

    assert_raise Exqlite.Error, ~r/UNIQUE/, fn ->
      Repo.query!(
        "INSERT INTO installation_settings (id, created_at, updated_at) VALUES (randomblob(16), datetime('now'), datetime('now'))"
      )
    end

    assert count() == 1
  end

  test "Ash.create of a second row is rejected, leaving one row" do
    assert {:ok, _} = Settings.set_nodes_local_max_workers(4)
    assert match?({:error, _}, Ash.create(Installation, %{}))
    assert count() == 1
  end

  test "concurrent first writes converge on a single row and the write is visible" do
    parent = self()

    results =
      1..8
      |> Task.async_stream(
        fn i ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Settings.set_nodes_local_max_workers(i)
        end,
        timeout: :infinity,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
    assert count() == 1
    assert Settings.nodes_local_max_workers() in 1..8
  end
end

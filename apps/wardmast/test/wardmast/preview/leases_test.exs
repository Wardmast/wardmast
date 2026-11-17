defmodule Wardmast.Preview.LeasesTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.Preview.Config
  alias Wardmast.Preview.Lease
  alias Wardmast.Preview.Leases

  @range {31_000, 31_009}

  defp acquire(repo, task_id, opts \\ []) do
    Leases.acquire(
      %{repo: repo, task_id: task_id},
      @range,
      Keyword.put_new(opts, :probe, fn _ -> true end)
    )
  end

  test "two previews of one repo and previews of different repos get distinct ports in range" do
    assert {:ok, a} = acquire("app", "bd-1")
    assert {:ok, b} = acquire("app", "bd-2")
    assert {:ok, c} = acquire("other", "bd-1")

    ports = [a.port, b.port, c.port]
    assert length(Enum.uniq(ports)) == 3
    assert Enum.all?(ports, &(&1 in 31_000..31_009))
  end

  test "never leases the server's port, a reserved port or a worker dev-server port" do
    {wlo, whi} = Config.worker_range()
    server_port = 31_003

    for i <- 1..9 do
      assert {:ok, lease} = acquire("app", "bd-#{i}", reserved: [server_port])
      refute lease.port == server_port
      refute lease.port in wlo..whi
    end

    # Range is 10 wide, 1 reserved, 9 taken: the next one has nowhere to go.
    assert {:error, :range_exhausted} = acquire("app", "bd-10", reserved: [server_port])
  end

  test "an out-of-range overlap with the worker range is refused outright" do
    assert {:error, :range_overlaps_worker_ports} =
             Leases.acquire(%{repo: "app", task_id: "bd-1"}, {29_990, 30_010},
               probe: fn _ -> true end
             )
  end

  test "skips ports that fail the free probe" do
    probe = fn port -> port != 31_000 end
    assert {:ok, lease} = acquire("app", "bd-1", probe: probe)
    assert lease.port == 31_001 or lease.port > 31_001
    refute lease.port == 31_000
  end

  test "release frees the port for the next preview" do
    for i <- 1..10, do: assert({:ok, _} = acquire("app", "bd-#{i}"))
    assert {:error, :range_exhausted} = acquire("app", "bd-11")

    lease = Leases.get("app", "bd-4")
    freed = lease.port
    assert {:ok, released} = Leases.release(lease)
    assert released.port == nil

    assert {:ok, again} = acquire("app", "bd-11")
    assert again.port == freed
  end

  test "the unique index rejects a second holder of a port" do
    assert {:ok, a} = acquire("app", "bd-1")
    {:ok, b} = acquire("app", "bd-2")

    assert {:error, _} =
             b
             |> Ecto.Changeset.change(port: a.port)
             |> Ecto.Changeset.unique_constraint(:port)
             |> Wardmast.Repo.update()
  end

  test "acquire is keyed by (repo, task_id): a live lease is refused, a failed one is replaced" do
    assert {:ok, lease} = acquire("app", "bd-1")
    assert {:error, {:already_leased, %Lease{}}} = acquire("app", "bd-1")

    assert {:ok, _} = Leases.update(lease, %{status: "failed", error: "boom"})
    assert {:ok, _} = Leases.release(Leases.get("app", "bd-1"))
    assert {:ok, again} = acquire("app", "bd-1")
    assert again.status == "starting"
    assert Wardmast.Repo.aggregate(Lease, :count) == 1
  end

  test "delete removes the row and the port is free again" do
    assert {:ok, lease} = acquire("app", "bd-1")
    assert :ok = Leases.delete(lease)
    assert Leases.get("app", "bd-1") == nil
    assert {:ok, again} = acquire("app", "bd-2")
    assert again.port == lease.port
  end

  test "a real free-port probe: a listening port is skipped" do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: false])
    {:ok, busy} = :inet.port(sock)

    refute Leases.port_free?(busy)
    :gen_tcp.close(sock)
  end
end

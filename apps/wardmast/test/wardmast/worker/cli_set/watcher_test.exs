defmodule Wardmast.Worker.CliSet.WatcherTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.Settings
  alias Wardmast.Worker.CliSet
  alias Wardmast.Worker.CliSet.Watcher
  alias Wardmast.Worker.CliSetFixture
  alias Wardmast.Worker.Image.PublishLedger

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    on_exit(fn -> Settings.set_worker_cli_set_hold(nil) end)

    ledger = Path.join(tmp, "ledger.term")
    now = ~U[2026-10-26 12:00:00Z]
    old = DateTime.add(now, -15 * 86_400, :second)
    recent = DateTime.add(now, -13 * 86_400, :second)

    PublishLedger.record(%{repo: "stale", repo_path: "/r/stale"}, ledger: ledger, now: old)
    PublishLedger.record(%{repo: "fresh", repo_path: "/r/fresh"}, ledger: ledger, now: recent)

    cli_opts = CliSetFixture.put(Path.join(tmp, "a"))
    test = self()

    opts = [
      name: nil,
      enabled: true,
      interval_ms: :infinity,
      boot_delay_ms: :infinity,
      ledger: ledger,
      now: now,
      cli_opts: cli_opts,
      publish: fn ctx ->
        send(test, {:published, ctx.repo})
        {:ok, %{ref: "r"}}
      end
    ]

    {:ok, opts: opts, tmp: tmp}
  end

  # A new upstream claude lands in the cache and the pin moves to it.
  defp bump(opts, tmp) do
    new = CliSetFixture.put(Path.join(tmp, "b"), claude: "2.1.311")
    Keyword.put(opts, :cli_opts, new)
  end

  defp drain(acc \\ []) do
    receive do
      {:published, repo} -> drain([repo | acc])
    after
      0 -> Enum.sort(acc)
    end
  end

  test "unheld, a bump republishes only the repos that published in the last 14 days", %{
    opts: opts,
    tmp: tmp
  } do
    pid = start_supervised!({Watcher, opts})
    assert {:republished, [{{"fresh", "/r/fresh"}, {:ok, _}}]} = Watcher.run_now(pid)
    assert drain() == ["fresh"]

    # The same set again: nothing to do.
    assert Watcher.run_now(pid) == :unchanged

    # The pin bump: pins change, the watcher is told by the settings event.
    :sys.replace_state(pid, fn state -> %{state | opts: bump(state.opts, tmp)} end)

    Phoenix.PubSub.broadcast(
      Wardmast.PubSub,
      Settings.topic(),
      {:installation_settings_changed, :worker_cli_versions}
    )

    _ = :sys.get_state(pid)

    assert drain() == ["fresh"]
  end

  test "held: a bump republishes nothing", %{opts: opts, tmp: tmp} do
    {:ok, _} = Settings.set_worker_cli_set_hold("a1b2c3d4")
    pid = start_supervised!({Watcher, bump(opts, tmp)})

    assert Watcher.run_now(pid) == :held

    Phoenix.PubSub.broadcast(
      Wardmast.PubSub,
      Settings.topic(),
      {:installation_settings_changed, :worker_cli_versions}
    )

    _ = :sys.get_state(pid)

    assert drain() == []
  end

  test "a bump with identical bytes republishes nothing", %{opts: opts, tmp: tmp} do
    pid = start_supervised!({Watcher, opts})
    assert {:republished, _} = Watcher.run_now(pid)
    _ = drain()

    same =
      CliSetFixture.put(Path.join(tmp, "c"),
        claude: "2.1.311",
        content: %{"claude" => "claude-binary-2.1.310"}
      )

    :sys.replace_state(pid, fn state ->
      %{state | opts: Keyword.put(state.opts, :cli_opts, same)}
    end)

    assert Watcher.run_now(pid) == :unchanged
  end

  test "held, the set resolves from the held snapshot whatever the pins say now", %{tmp: tmp} do
    a = CliSetFixture.put(Path.join(tmp, "a"))
    {:ok, set} = CliSet.resolve(a)
    {:ok, set} = CliSet.materialize(set)
    {:ok, _} = Settings.set_worker_cli_set_hold(set.set8)

    b = CliSetFixture.put(Path.join(tmp, "b"), claude: "2.1.311")
    # Same sets root, new cache: the pins moved.
    b = Keyword.put(b, :cli_sets_root, Keyword.fetch!(a, :cli_sets_root))
    assert {:ok, bumped} = CliSet.resolve(Keyword.delete(b, :cli_set))
    assert bumped.hash == set.hash
    assert Enum.find(bumped.clis, &(&1.name == "claude")).version == "2.1.310"
    assert {:ok, _} = CliSet.materialize(bumped, verify: true)

    # Under the hold the shipped escript is the snapshot's, not the host's.
    escript = CliSet.arb_escript(Keyword.delete(b, :cli_set))
    assert is_binary(escript)
    assert escript =~ "/arb/arb.escript"
    assert escript =~ Keyword.fetch!(a, :cli_sets_root)

    {:ok, _} = Settings.set_worker_cli_set_hold(nil)
    assert {:ok, moved} = CliSet.resolve(b)
    refute moved.hash == set.hash
  end

  test "a publish that outlives the wait logs still publishing, not failed, and is retried", %{
    opts: opts
  } do
    opts =
      Keyword.put(opts, :publish, fn _ctx -> {:error, {:timeout, 1_800_000}} end)

    pid = start_supervised!({Watcher, opts})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:republished, [{{"fresh", "/r/fresh"}, {:still_publishing, 1800}}]} =
                 Watcher.run_now(pid)
      end)

    assert log =~ "still publishing (1800s)"
    refute log =~ "failed"

    # Not marked done: the next check joins the same flight again.
    assert {:republished, [_]} = Watcher.run_now(pid)
  end

  test "transient push failure (exit 125 DNS/ping error or timeout) retries with backoff and clears on success",
       %{opts: opts} do
    test = self()
    counter = :counters.new(1, [:atomics])
    fail_ref = "ghcr.io/wardmast/arbiter/fresh/worker:4efb919d29e0"
    ok_ref = "ghcr.io/wardmast/arbiter/fresh/worker@sha256:" <> String.duplicate("a", 64)

    dns_err =
      {:push_failed, fail_ref, 125,
       "Error: trying to reuse blob sha256:1234 at destination: pinging container registry ghcr.io: " <>
         "Get \"https://ghcr.io/v2/\": dial tcp: lookup ghcr.io: Temporary failure in name resolution"}

    publish = fn ctx ->
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)
      send(test, {:attempt, attempt, ctx.repo})

      case attempt do
        1 -> {:error, dns_err}
        2 -> {:error, {:timeout, 600_000}}
        _ -> {:ok, %{ref: ok_ref}}
      end
    end

    pid = start_supervised!({Watcher, Keyword.put(opts, :publish, publish)})

    # Attempt 1: transient DNS failure -> scheduled at first backoff step (1m), retry state recorded.
    log1 =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:republished, [{{"fresh", "/r/fresh"}, {:error, ^dns_err}}]} =
                 Watcher.run_now(pid)
      end)

    assert_received {:attempt, 1, "fresh"}
    assert log1 =~ fail_ref
    assert log1 =~ "1m"

    status1 = Watcher.status(pid)

    assert %{attempts: 1, next_delay_ms: 60_000, ref: ^fail_ref} =
             status1.retries[{"fresh", "/r/fresh"}]

    assert status1.failed == %{}
    assert status1.last_hash == nil

    # Attempt 2: timeout -> advances backoff to second step (5m), logs retry with image ref.
    log2 =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:republished, [{{"fresh", "/r/fresh"}, {:still_publishing, 600}}]} =
                 Watcher.run_now(pid)
      end)

    assert_received {:attempt, 2, "fresh"}
    assert log2 =~ "retrying republish"
    assert log2 =~ fail_ref
    assert log2 =~ "5m"

    status2 = Watcher.status(pid)
    assert %{attempts: 2, next_delay_ms: 300_000} = status2.retries[{"fresh", "/r/fresh"}]

    # Attempt 3: succeeds -> clears retry state, advances last_hash, logs final outcome with image ref.
    log3 =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:republished, [{{"fresh", "/r/fresh"}, {:ok, %{ref: ^ok_ref}}}]} =
                 Watcher.run_now(pid)
      end)

    assert_received {:attempt, 3, "fresh"}
    assert log3 =~ "retrying republish"
    assert log3 =~ "succeeded after 2 retries"
    assert log3 =~ ok_ref

    status3 = Watcher.status(pid)
    assert status3.retries == %{}
    assert status3.failed == %{}
    assert is_binary(status3.last_hash)

    # Subsequent tick/run is a no-op.
    assert Watcher.run_now(pid) == :unchanged
  end

  test "backoff schedule progresses 1m -> 5m -> 15m -> 1h (capped) and timer drives retries", %{
    opts: opts
  } do
    assert Watcher.backoff_ms(1) == :timer.minutes(1)
    assert Watcher.backoff_ms(2) == :timer.minutes(5)
    assert Watcher.backoff_ms(3) == :timer.minutes(15)
    assert Watcher.backoff_ms(4) == :timer.hours(1)
    assert Watcher.backoff_ms(10) == :timer.hours(1)

    test = self()
    counter = :counters.new(1, [:atomics])
    fail_ref = "ghcr.io/wardmast/arbiter/fresh/worker:4efb919d29e0"
    ok_ref = "ghcr.io/wardmast/arbiter/fresh/worker@sha256:" <> String.duplicate("b", 64)

    publish = fn _ctx ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test, {:timer_attempt, n})

      if n < 3 do
        {:error, {:push_failed, fail_ref, 125, "pinging container registry: i/o timeout"}}
      else
        {:ok, %{ref: ok_ref}}
      end
    end

    fast_opts =
      opts
      |> Keyword.put(:publish, publish)
      |> Keyword.put(:boot_delay_ms, 10)
      |> Keyword.put(:retry_schedule_ms, [15, 25, 50])

    pid = start_supervised!({Watcher, fast_opts})

    assert_receive {:timer_attempt, 1}, 1_000
    assert_receive {:timer_attempt, 2}, 1_000
    assert_receive {:timer_attempt, 3}, 1_000

    _ = :sys.get_state(pid)
    assert Watcher.status(pid).retries == %{}
    assert is_binary(Watcher.status(pid).last_hash)
  end

  test "auth/denied failure is not retried indefinitely and surfaces as a persistent failure", %{
    opts: opts
  } do
    test = self()
    ref = "ghcr.io/wardmast/arbiter/fresh/worker:4efb919d29e0"

    denied =
      {:push_failed, ref, 125,
       "Error: pushing image to docker://#{ref}: unauthorized: authentication required"}

    publish = fn ctx ->
      send(test, {:published, ctx.repo})
      {:error, denied}
    end

    pid = start_supervised!({Watcher, Keyword.put(opts, :publish, publish)})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:republished, [{{"fresh", "/r/fresh"}, {:error, ^denied}}]} =
                 Watcher.run_now(pid)
      end)

    assert drain() == ["fresh"]
    assert log =~ ref
    assert log =~ "failed permanently"

    # Not scheduled for retry, and recorded as a persistent failure.
    status = Watcher.status(pid)
    assert status.retries == %{}
    assert %{ref: ^ref, reason: ^denied, attempts: 1} = status.failed[{"fresh", "/r/fresh"}]

    # Subsequent checks/ticks for the same CLI set do not retry the permanent failure.
    assert Watcher.run_now(pid) == :unchanged
    send(pid, :tick)
    _ = :sys.get_state(pid)
    assert drain() == []

    # Surfaced in CliFetcher.Status (for doctor) and in the coordinator inbox.
    cli_status = Wardmast.Worker.CliFetcher.Status.build(watcher_status: status)
    assert [%{repo: "fresh", ref: ^ref, reason: reason_text}] = cli_status.republish.failed
    assert reason_text =~ "unauthorized"

    inbox = Wardmast.Messages.Mailbox.list(to_ref: "coordinator", state: :unread)
    assert Enum.any?(inbox, &(&1.subject =~ "fresh" and &1.body =~ ref))
  end

  test "gating on registry reachability defers publish until registry is reachable", %{
    opts: opts
  } do
    test = self()
    reachable = :atomics.new(1, [])
    :atomics.put(reachable, 1, 0)

    probe = fn _target ->
      if :atomics.get(reachable, 1) == 1, do: :ok, else: {:error, :nxdomain}
    end

    publish = fn ctx ->
      send(test, {:published, ctx.repo})
      {:ok, %{ref: "ghcr.io/wardmast/arbiter/fresh/worker@sha256:" <> String.duplicate("c", 64)}}
    end

    pid =
      start_supervised!(
        {Watcher, opts |> Keyword.put(:probe, probe) |> Keyword.put(:publish, publish)}
      )

    assert {:republished,
            [{{"fresh", "/r/fresh"}, {:error, {:registry_unreachable, _, :nxdomain}}}]} =
             Watcher.run_now(pid)

    assert drain() == []
    assert Map.has_key?(Watcher.status(pid).retries, {"fresh", "/r/fresh"})

    :atomics.put(reachable, 1, 1)
    assert {:republished, [{{"fresh", "/r/fresh"}, {:ok, _}}]} = Watcher.run_now(pid)
    assert drain() == ["fresh"]
    assert Watcher.status(pid).retries == %{}
  end

  test "classify_error distinguishes transient network/timeout errors from permanent auth/config errors" do
    assert Watcher.classify_error(
             {:push_failed, "ghcr.io/wardmast/arbiter/worker:1", 125,
              "pinging container registry ghcr.io: dial tcp: lookup ghcr.io: Temporary failure in name resolution"}
           ) == :transient

    assert Watcher.classify_error(
             {:push_failed, "ghcr.io/wardmast/arbiter/worker:1", 125,
              "Get \"https://ghcr.io/v2/\": dial tcp 1.2.3.4:443: connect: connection refused"}
           ) == :transient

    assert Watcher.classify_error({:timeout, 600_000}) == :transient
    assert Watcher.classify_error({:still_publishing, 600}) == :transient
    assert Watcher.classify_error(:publisher_busy) == :transient
    assert Watcher.classify_error({:registry_unreachable, "r", :nxdomain}) == :transient

    assert Watcher.classify_error(
             {:push_failed, "ghcr.io/wardmast/arbiter/worker:1", 125,
              "unauthorized: authentication required"}
           ) == :permanent

    assert Watcher.classify_error(
             {:push_failed, "ghcr.io/wardmast/arbiter/worker:1", 125,
              "denied: requested access to the resource is denied"}
           ) == :permanent

    assert Watcher.classify_error({:public_registry, "ghcr.io/wardmast/arbiter/worker"}) ==
             :permanent

    assert Watcher.classify_error({:registry_credentials, "secret:GHCR", :secret_not_found}) ==
             :permanent
  end

  test "repeated transient failures surface a persistent failure after threshold and clear on recovery",
       %{opts: opts, tmp: tmp} do
    ledger = Keyword.fetch!(opts, :ledger)
    now = Keyword.fetch!(opts, :now)
    PublishLedger.record(%{repo: "second", repo_path: "/r/second"}, ledger: ledger, now: now)

    counter = :counters.new(1, [:atomics])
    ref = "ghcr.io/wardmast/arbiter/fresh/worker:4efb919d29e0"
    ok_ref = "ghcr.io/wardmast/arbiter/fresh/worker@sha256:" <> String.duplicate("d", 64)
    test = self()

    publish = fn
      %{repo: "second"} ->
        send(test, {:published, "second"})

        {:ok,
         %{ref: "ghcr.io/wardmast/arbiter/second/worker@sha256:" <> String.duplicate("e", 64)}}

      %{repo: "fresh"} ->
        :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(test, {:published, "fresh"})

        if attempt <= 3 do
          {:error, {:push_failed, ref, 125, "pinging container registry: connection reset"}}
        else
          {:ok, %{ref: ok_ref}}
        end
    end

    pid = start_supervised!({Watcher, Keyword.put(opts, :publish, publish)})

    # Attempt 1: "second" succeeds, "fresh" fails transiently.
    assert {:republished, _} = Watcher.run_now(pid)
    assert drain() == ["fresh", "second"]

    # Periodic :tick while a retry timer is scheduled does not preempt the backoff.
    send(pid, :tick)
    _ = :sys.get_state(pid)
    assert drain() == []

    # Attempt 2: only "fresh" is retried ("second" already succeeded for this CLI set).
    assert {:republished, [{{"fresh", "/r/fresh"}, {:error, _}}]} = Watcher.run_now(pid)
    assert drain() == ["fresh"]
    assert Watcher.status(pid).failed == %{}

    # Attempt 3: hits persistent transient threshold -> surfaced in failed and inbox while still retrying.
    assert {:republished, [{{"fresh", "/r/fresh"}, {:error, _}}]} = Watcher.run_now(pid)
    assert drain() == ["fresh"]
    assert Map.has_key?(Watcher.status(pid).failed, {"fresh", "/r/fresh"})
    assert Map.has_key?(Watcher.status(pid).retries, {"fresh", "/r/fresh"})

    assert Enum.any?(
             Wardmast.Messages.Mailbox.list(to_ref: "coordinator", state: :unread),
             &(&1.subject =~ "fresh" and &1.body =~ ref)
           )

    # Attempt 4: succeeds -> clears both retry state, failed state, and the coordinator notice.
    assert {:republished, [{{"fresh", "/r/fresh"}, {:ok, %{ref: ^ok_ref}}}]} =
             Watcher.run_now(pid)

    assert Watcher.status(pid).retries == %{}
    assert Watcher.status(pid).failed == %{}

    refute Enum.any?(
             Wardmast.Messages.Mailbox.list(to_ref: "coordinator", state: :unread),
             &(&1.subject =~ "fresh" and &1.body =~ ref)
           )

    _ = tmp
  end
end

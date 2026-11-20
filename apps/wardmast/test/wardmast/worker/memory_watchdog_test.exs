defmodule Wardmast.Worker.MemoryWatchdogTest do
  # bd-d627b8 (MAC P3-3): macOS has no cgroups, so the per-worker memory cap is a
  # polling watchdog over the agent's process group. Everything here injects the
  # sampler (`ps` is never run), the killer and the clock-free `poll/1` step.
  use ExUnit.Case, async: true

  alias Wardmast.Worker.MemoryWatchdog

  @gib 1_073_741_824

  describe "cap/1" do
    test "is off by default on darwin: the cap is opt-in" do
      assert MemoryWatchdog.cap(os: :darwin, env: nil, config: nil) == :disabled
    end

    test "is always off on other hosts (systemd scopes do that job)" do
      assert MemoryWatchdog.cap(os: :linux, env: "12G", config: nil) == :disabled
    end

    test "parses a size from the environment" do
      assert MemoryWatchdog.cap(os: :darwin, env: "12G", config: nil) ==
               {:ok, %{bytes: 12 * @gib, label: "12G"}}

      assert MemoryWatchdog.cap(os: :darwin, env: "512m", config: nil) ==
               {:ok, %{bytes: 512 * 1_048_576, label: "512M"}}
    end

    test "the environment beats application config" do
      assert {:ok, %{label: "2G"}} = MemoryWatchdog.cap(os: :darwin, env: "2G", config: "9G")
      assert {:ok, %{label: "9G"}} = MemoryWatchdog.cap(os: :darwin, env: nil, config: "9G")
    end

    test "a percentage is of physical RAM" do
      assert MemoryWatchdog.cap(os: :darwin, env: "50%", config: nil, total_memory: 16 * @gib) ==
               {:ok, %{bytes: 8 * @gib, label: "50%"}}
    end

    test "a percentage with unknown physical RAM is off, not a guess" do
      assert MemoryWatchdog.cap(os: :darwin, env: "50%", config: nil, total_memory: nil) ==
               :disabled
    end

    test "off / 0 / none / infinity disable it" do
      for v <- ~w(off 0 none infinity) do
        assert MemoryWatchdog.cap(os: :darwin, env: v, config: nil) == :disabled
      end
    end

    test "an unparseable value is off" do
      assert MemoryWatchdog.cap(os: :darwin, env: "lots", config: nil) == :disabled
    end
  end

  describe "parse_rss/2" do
    test "sums the rss (KiB) of the rows in the group and ignores the rest" do
      out = """
        100  2048
        100  1024
        200  9999
        100     1
      """

      assert MemoryWatchdog.parse_rss(out, 100) == {:ok, (2048 + 1024 + 1) * 1024}
    end

    test "a group with no rows is zero" do
      assert MemoryWatchdog.parse_rss("  200 10\n", 100) == {:ok, 0}
    end

    test "ignores lines that are not two integers" do
      assert MemoryWatchdog.parse_rss("ps: warning\n  100 4\n", 100) == {:ok, 4096}
    end
  end

  describe "poll/1" do
    defp state(overrides) do
      test_pid = self()

      MemoryWatchdog.new_state(
        Keyword.merge(
          [
            owner: test_pid,
            group: %{pid: 100, pgid: 100, started_at: nil},
            cap: %{bytes: 10 * @gib, label: "10G"},
            sampler: fn 100 -> {:ok, 1 * @gib} end,
            killer: fn group ->
              send(test_pid, {:killed, group.pgid})
              :ok
            end
          ],
          overrides
        )
      )
    end

    test "under the cap: nothing happens and the peak is tracked" do
      s = state(sampler: fn 100 -> {:ok, 3 * @gib} end)
      assert {:ok, s} = MemoryWatchdog.poll(s)
      assert s.peak == 3 * @gib
      refute_received {:killed, _}
      refute_received {:memory_watchdog_exceeded, _, _}
    end

    test "over the cap: tells the owner, then kills the group" do
      s = state(sampler: fn 100 -> {:ok, 11 * @gib} end)
      assert {:exceeded, _s} = MemoryWatchdog.poll(s)

      assert_received {:memory_watchdog_exceeded, 100,
                       %{max: "10G", peak: peak, source: :watchdog}}

      assert peak == 11 * @gib
      assert_received {:killed, 100}
    end

    test "exactly at the cap is not over it" do
      s = state(sampler: fn 100 -> {:ok, 10 * @gib} end)
      assert {:ok, _} = MemoryWatchdog.poll(s)
      refute_received {:killed, _}
    end

    test "a failed sample is skipped, not treated as over" do
      s = state(sampler: fn 100 -> :error end)
      assert {:ok, _} = MemoryWatchdog.poll(s)
      refute_received {:killed, _}
    end

    test "the reported peak is the highest seen, not just the last sample" do
      {:ok, calls} = Agent.start_link(fn -> [12 * @gib, 4 * @gib] end)

      sampler = fn 100 -> {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)} end
      s = state(cap: %{bytes: 20 * @gib, label: "20G"}, sampler: sampler)

      {:ok, s} = MemoryWatchdog.poll(s)
      {:ok, s} = MemoryWatchdog.poll(s)
      assert s.peak == 12 * @gib
    end
  end

  describe "the process" do
    test "kills and reports once a sample is over the cap, then stops" do
      test_pid = self()

      {:ok, pid} =
        MemoryWatchdog.start(
          owner: test_pid,
          group: %{pid: 100, pgid: 100, started_at: nil},
          cap: %{bytes: 1 * @gib, label: "1G"},
          interval_ms: 5,
          sampler: fn 100 -> {:ok, 2 * @gib} end,
          killer: fn group ->
            send(test_pid, {:killed, group.pgid})
            :ok
          end
        )

      ref = Process.monitor(pid)
      assert_receive {:memory_watchdog_exceeded, 100, %{max: "1G"}}, 1_000
      assert_receive {:killed, 100}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end

    test "stop/1 ends it without killing anything" do
      test_pid = self()

      {:ok, pid} =
        MemoryWatchdog.start(
          owner: test_pid,
          group: %{pid: 100, pgid: 100, started_at: nil},
          cap: %{bytes: 1 * @gib, label: "1G"},
          interval_ms: 5,
          sampler: fn 100 -> {:ok, 0} end,
          killer: fn group ->
            send(test_pid, {:killed, group.pgid})
            :ok
          end
        )

      ref = Process.monitor(pid)
      assert :ok = MemoryWatchdog.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      refute_received {:killed, _}
    end

    test "it exits when its owner does" do
      owner = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, pid} =
        MemoryWatchdog.start(
          owner: owner,
          group: %{pid: 100, pgid: 100, started_at: nil},
          cap: %{bytes: 1 * @gib, label: "1G"},
          interval_ms: 5,
          sampler: fn 100 -> {:ok, 0} end,
          killer: fn _ -> :ok end
        )

      ref = Process.monitor(pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end

    test "stop/1 of nil or a dead pid is a no-op" do
      assert :ok = MemoryWatchdog.stop(nil)
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert :ok = MemoryWatchdog.stop(pid)
    end
  end

  describe "maybe_start/2" do
    test "starts nothing when the cap is disabled" do
      group = %{pid: 100, pgid: 100, started_at: nil}
      assert MemoryWatchdog.maybe_start(group, owner: self(), cap: :disabled) == group
    end

    test "starts nothing for a group that has no pgid (it is never group-killed)" do
      group = %{pid: 100, pgid: nil, started_at: nil}

      assert MemoryWatchdog.maybe_start(group,
               owner: self(),
               cap: {:ok, %{bytes: 1, label: "1"}}
             ) == group
    end

    test "starts nothing for no group" do
      assert MemoryWatchdog.maybe_start(nil, owner: self(), cap: {:ok, %{bytes: 1, label: "1"}}) ==
               nil
    end

    test "records the watchdog pid on the group when enabled" do
      group = %{pid: 100, pgid: 100, started_at: nil}

      %{watchdog: pid} =
        MemoryWatchdog.maybe_start(group,
          owner: self(),
          cap: {:ok, %{bytes: 1 * @gib, label: "1G"}},
          interval_ms: 60_000,
          sampler: fn _ -> {:ok, 0} end
        )

      assert is_pid(pid)
      ref = Process.monitor(pid)
      MemoryWatchdog.stop(pid)
      assert_receive {:DOWN, ^ref, _, _, _}, 1_000
    end
  end
end

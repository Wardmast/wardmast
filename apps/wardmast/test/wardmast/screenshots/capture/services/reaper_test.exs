defmodule Wardmast.Screenshots.Capture.Services.ReaperTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture.Services.Reaper

  defp container(n), do: "arb-cap-test-#{n}"

  defp idle_owner do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  test "track/3 is answered while a slow boot sweep runs, and the container is then reaped" do
    test = self()

    runner = fn _cmd, args, _opts ->
      case args do
        ["ps" | _] ->
          send(test, {:sweeping, self()})

          receive do
            :release_sweep -> {"[]", 0}
          end

        ["rm" | _] ->
          send(test, {:rm, List.last(args)})
          {"", 0}
      end
    end

    reaper =
      start_supervised!(
        {Reaper,
         name: nil, enabled: true, runner: runner, podman: "podman", alive?: fn _ -> false end}
      )

    assert_receive {:sweeping, sweep}, 5_000

    owner = idle_owner()

    task =
      Task.async(fn ->
        Reaper.track(reaper, owner, {:container, container(1), [runner: runner]})
      end)

    # Answered in well under the 15 s call timeout while the sweep is still blocked.
    assert {:ok, :ok} =
             Task.yield(task, 1_000) |> then(&(&1 || Task.shutdown(task, :brutal_kill)))

    send(sweep, :release_sweep)
    Process.exit(owner, :kill)
    name = container(1)
    assert_receive {:rm, ^name}, 5_000
  end

  test "terminate removes several tracked containers in parallel within the shutdown budget" do
    test = self()

    runner = fn _cmd, args, _opts ->
      Process.sleep(500)
      send(test, {:rm, List.last(args)})
      {"", 0}
    end

    {:ok, reaper} = Reaper.start_link(name: nil, enabled: false)
    Process.unlink(reaper)
    owner = idle_owner()

    names = for n <- 1..6, do: container(n)

    for name <- names,
        do:
          :ok =
            Reaper.track(reaper, owner, {:container, name, [runner: runner, podman: "podman"]})

    {micros, :ok} = :timer.tc(fn -> GenServer.stop(reaper, :shutdown, 10_000) end)

    for name <- names, do: assert_received({:rm, ^name})
    # Serial would be >= 3 s; parallel is about one removal.
    assert micros < 2_000_000
  end
end

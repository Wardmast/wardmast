defmodule Wardmast.Machine.LocalTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.Machine.Local
  alias Wardmast.Settings

  setup do
    previous = Application.fetch_env(:wardmast, :machine_monitor)

    on_exit(fn ->
      Settings.set_machine_derate(nil)

      case previous do
        {:ok, v} -> Application.put_env(:wardmast, :machine_monitor, v)
        :error -> Application.delete_env(:wardmast, :machine_monitor)
      end
    end)
  end

  test "the primary's thresholds are the machine.derate setting over the defaults" do
    assert Local.config().thermal_soft_c == 90.0
    {:ok, _} = Settings.set_machine_derate(%{"thermal_soft_c" => 80, "enabled" => true})
    assert Local.config().thermal_soft_c == 80.0
    assert Local.config().thermal_hard_c == 95.0
  end

  test "on by default; :machine_monitor false keeps it from starting" do
    Application.delete_env(:wardmast, :machine_monitor)
    assert [{Wardmast.Machine.Monitor, opts}] = Local.child_specs()
    assert opts[:name] == Wardmast.Machine.Monitor

    Application.put_env(:wardmast, :machine_monitor, false)
    assert Local.child_specs() == []
  end

  test "the real monitor child samples this host and LocalCapacity reads it" do
    Application.put_env(:wardmast, :machine_monitor, true)
    # The app's own `Local` supervisor runs empty in the suite (monitor off); start its child.
    start_supervised!(hd(Local.child_specs()))
    snapshot = Wardmast.Machine.Monitor.sample()
    assert snapshot.level in [:none, :soft, :hard]
    assert is_integer(snapshot.offered)
    assert Wardmast.Nodes.LocalCapacity.cap().derate == snapshot.level
  end
end

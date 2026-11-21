defmodule Wardmast.KeyBackupTest do
  use ExUnit.Case, async: false

  alias Wardmast.KeyBackup

  setup do
    home = Path.join(System.tmp_dir!(), "arb-keybackup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = Application.fetch_env(:wardmast, :data_dir)
    Application.put_env(:wardmast, :data_dir, home)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:wardmast, :data_dir, v)
        :error -> Application.delete_env(:wardmast, :data_dir)
      end

      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "no record until a backup is made" do
    assert KeyBackup.status() == :none
  end

  test "the warning says losing the key makes stored secrets unreadable" do
    assert KeyBackup.warning() =~ "unreadable"
  end

  test "export returns the key once and records a backup without the key in it", %{home: home} do
    assert {:ok, key, record} = KeyBackup.export()

    assert key == Base.encode64(Wardmast.Vault.key!())
    assert record.method == "export"

    assert {:recorded, %{method: "export", recorded_at: %DateTime{}, fingerprint: fp}} =
             KeyBackup.status()

    assert fp == KeyBackup.fingerprint(Wardmast.Vault.key!())

    # The record on disk holds a fingerprint, never the key.
    body = File.read!(Path.join(home, "cloak-key-backup.json"))
    refute body =~ key
    refute body =~ Base.encode64(Wardmast.Vault.key!(), padding: false)
    assert Jason.decode!(body)["fingerprint"] == fp
  end

  test "the export is one-time: a second attempt is refused" do
    assert {:ok, _, _} = KeyBackup.export()
    assert {:error, :already_recorded} = KeyBackup.export()
  end

  test "acknowledging a backup made elsewhere records it without exposing the key" do
    assert {:ok, record} = KeyBackup.acknowledge()
    assert record.method == "manual"
    assert {:recorded, %{method: "manual"}} = KeyBackup.status()
    assert {:error, :already_recorded} = KeyBackup.export()
  end

  test "a record file lets the CLI doctor read it: json with the documented fields", %{home: home} do
    {:ok, _} = KeyBackup.acknowledge()

    assert %{"recorded_at" => at, "method" => "manual", "fingerprint" => _} =
             home |> Path.join("cloak-key-backup.json") |> File.read!() |> Jason.decode!()

    assert {:ok, _, _} = DateTime.from_iso8601(at)
  end

  test "a corrupt record counts as no backup", %{home: home} do
    File.write!(Path.join(home, "cloak-key-backup.json"), "not json")
    assert KeyBackup.status() == :none
  end
end

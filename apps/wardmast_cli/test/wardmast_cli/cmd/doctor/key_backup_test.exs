defmodule WardmastCli.Cmd.Doctor.KeyBackupTest do
  use ExUnit.Case, async: true

  alias WardmastCli.Cmd.Doctor.KeyBackup

  setup do
    home = Path.join(System.tmp_dir!(), "arb-kbdoc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  test "n/a when there is no data home at all" do
    missing =
      Path.join(System.tmp_dir!(), "arb-kbdoc-missing-#{System.unique_integer([:positive])}")

    assert %{status: :na} = KeyBackup.check({:home, missing})
  end

  test "warns when no backup has been recorded, saying what is at stake and how to fix it", %{
    home: home
  } do
    result = KeyBackup.check({:home, home})

    assert result.status == :warn
    assert result.detail =~ "no backup"
    assert result.detail =~ "unreadable"
    assert result.hint =~ "/settings/key-backup"
  end

  test "ok once a backup is recorded; the record's fingerprint is shown, never a key", %{
    home: home
  } do
    File.write!(
      Path.join(home, "cloak-key-backup.json"),
      Jason.encode!(%{
        "recorded_at" => "2026-11-20T10:00:00Z",
        "method" => "export",
        "fingerprint" => "deadbeef"
      })
    )

    result = KeyBackup.check({:home, home})
    assert result.status == :ok
    assert result.detail =~ "2026-11-20"
    assert result.detail =~ "deadbeef"
  end

  test "a corrupt record is no backup", %{home: home} do
    File.write!(Path.join(home, "cloak-key-backup.json"), "{")
    assert %{status: :warn} = KeyBackup.check({:home, home})
  end

  test "the probe override reaches check/0" do
    Process.put(:bd9_key_backup_probe, :absent)
    assert %{status: :na} = KeyBackup.check()
  end
end

defmodule WardmastWeb.KeyBackupControllerTest do
  @moduledoc "The dashboard's one-time Cloak key export and backup record."
  use WardmastWeb.ConnCase, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "arb-kbc-#{System.unique_integer([:positive])}")
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

    :ok
  end

  test "the page carries the warning and the export control, without the key" do
    html = html_response(get(dashboard_login(build_conn()), "/settings/key-backup"), 200)

    assert html =~ "key-backup-warning"
    assert html =~ "unreadable"
    assert html =~ "key-backup-export-form"
    assert html =~ "key-backup-ack-form"
    refute html =~ Base.encode64(Wardmast.Vault.key!())
  end

  test "export downloads the key once and records the backup" do
    conn = post(dashboard_login(build_conn()), "/settings/key-backup/export", %{})

    assert response(conn, 200) == Base.encode64(Wardmast.Vault.key!()) <> "\n"
    assert [cd] = get_resp_header(conn, "content-disposition")
    assert cd =~ "attachment"
    assert [cc] = get_resp_header(conn, "cache-control")
    assert cc =~ "no-store"

    assert {:recorded, %{method: "export"}} = Wardmast.KeyBackup.status()

    again = post(dashboard_login(build_conn()), "/settings/key-backup/export", %{})
    assert redirected_to(again) == "/settings/key-backup"
    assert Phoenix.Flash.get(again.assigns.flash, :error) =~ "already"
  end

  test "the page reports a recorded backup and no longer offers the export" do
    {:ok, _} = Wardmast.KeyBackup.acknowledge()
    html = html_response(get(dashboard_login(build_conn()), "/settings/key-backup"), 200)

    assert html =~ "key-backup-recorded"
    refute html =~ "key-backup-export-form"
  end

  test "acknowledge records a backup made elsewhere" do
    conn = post(dashboard_login(build_conn()), "/settings/key-backup/acknowledge", %{})
    assert redirected_to(conn) == "/settings/key-backup"
    assert {:recorded, %{method: "manual"}} = Wardmast.KeyBackup.status()
  end

  test "an anonymous browser gets neither the page nor the key" do
    for conn <- [
          get(build_conn(), "/settings/key-backup"),
          post(build_conn(), "/settings/key-backup/export", %{})
        ] do
      assert conn.status in [302, 401, 403]
      refute conn.resp_body =~ Base.encode64(Wardmast.Vault.key!())
    end

    assert Wardmast.KeyBackup.status() == :none
  end
end

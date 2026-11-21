defmodule WardmastWeb.KeyBackupController do
  @moduledoc """
  The Cloak key backup page (`/settings/key-backup`): a clear warning that losing
  the key makes every stored secret unreadable, a one-time export of the key,
  and a way to record a backup made elsewhere. See `Wardmast.KeyBackup`.

  Behind a dashboard login only. The key is never rendered into a page: the
  export is a POST whose response is an attachment (`cache-control: no-store`),
  and it is refused once a backup is on record.
  """

  use WardmastWeb, :controller

  alias Wardmast.KeyBackup

  def show(conn, _params) do
    render(conn, :show,
      status: KeyBackup.status(),
      warning: KeyBackup.warning()
    )
  end

  def export(conn, _params) do
    case KeyBackup.export() do
      {:ok, key, _record} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="wardmast-cloak-key.txt")
        )
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, key <> "\n")

      {:error, :already_recorded} ->
        conn
        |> put_flash(
          :error,
          "A key backup is already recorded, so the one-time export is closed."
        )
        |> redirect(to: ~p"/settings/key-backup")

      {:error, _} ->
        conn
        |> put_flash(:error, "The key could not be exported; nothing was recorded.")
        |> redirect(to: ~p"/settings/key-backup")
    end
  end

  def acknowledge(conn, _params) do
    case KeyBackup.acknowledge() do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Recorded: the Cloak key is backed up.")
        |> redirect(to: ~p"/settings/key-backup")

      {:error, :already_recorded} ->
        conn
        |> put_flash(:error, "A key backup is already recorded.")
        |> redirect(to: ~p"/settings/key-backup")

      {:error, _} ->
        conn
        |> put_flash(:error, "The backup could not be recorded.")
        |> redirect(to: ~p"/settings/key-backup")
    end
  end
end

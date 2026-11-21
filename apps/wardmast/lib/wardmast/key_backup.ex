defmodule Wardmast.KeyBackup do
  @moduledoc """
  The Cloak key backup record, and the one-time export that makes it.

  Every workspace credential is encrypted with the Cloak key
  (`Wardmast.Vault`). **Losing the key makes every stored secret unreadable**,
  and the desktop shell keeps it only in the OS keychain, so an operator must
  back it up once. This module:

    * `export/0` — hands back the Base64 key a single time and records that the
      backup was made;
    * `acknowledge/0` — records a backup the operator made some other way (a
      password manager, the secret manager the key ref points at);
    * `status/0` — what `arb server doctor` reads (`WardmastCli.KeyBackup` reads
      the same file) to warn when no backup is recorded.

  The record is `<data-home>/cloak-key-backup.json`:
  `{"recorded_at": ISO8601, "method": "export" | "manual", "fingerprint": hex8}`.
  The fingerprint is the first 8 hex characters of the key's SHA-256, enough to
  recognise which key a backup belongs to and useless for recovering it. The key
  itself is never written here.

  The export is one-time by design: once a record exists `export/0` refuses, so
  the key is not available to anyone who later reaches the dashboard. If the
  exported file is lost while the key is still in the keychain, delete
  `cloak-key-backup.json` to make a fresh export possible.
  """

  alias Wardmast.Nodes.Agent
  alias Wardmast.Vault

  @file_name "cloak-key-backup.json"

  @type t :: %{
          recorded_at: DateTime.t(),
          method: String.t(),
          fingerprint: String.t()
        }

  @warning "Losing the Cloak key makes every stored secret unreadable. Wardmast cannot " <>
             "regenerate or recover it: without this key, the provider credentials and " <>
             "other secrets stored in your workspaces cannot be decrypted. Store the " <>
             "exported key somewhere safe and separate from this machine (a password " <>
             "manager, an encrypted drive)."

  @doc "The warning shown beside every export / backup control."
  @spec warning() :: String.t()
  def warning, do: @warning

  @doc "Path of the record file."
  @spec path() :: String.t()
  def path, do: Path.join(Agent.data_home(), @file_name)

  @doc "`{:recorded, record}` once a backup has been recorded, else `:none`."
  @spec status() :: {:recorded, t()} | :none
  def status do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"recorded_at" => at, "method" => method, "fingerprint" => fp}} <-
           Jason.decode(body),
         {:ok, recorded_at, _} <- DateTime.from_iso8601(at) do
      {:recorded, %{recorded_at: recorded_at, method: method, fingerprint: fp}}
    else
      _ -> :none
    end
  end

  @doc "The first 8 hex characters of the key's SHA-256."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(key) when is_binary(key) do
    :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  @doc """
  Export the current Cloak key (Base64) and record the backup. Refuses with
  `{:error, :already_recorded}` once a backup is on record.
  """
  @spec export() :: {:ok, String.t(), t()} | {:error, :already_recorded | term()}
  def export do
    with :none <- status(),
         key = Vault.key!(),
         {:ok, record} <- record("export", key) do
      {:ok, Base.encode64(key), record}
    else
      {:recorded, _} -> {:error, :already_recorded}
      {:error, _} = error -> error
    end
  end

  @doc "Record a backup made outside Wardmast. Never exposes the key."
  @spec acknowledge() :: {:ok, t()} | {:error, :already_recorded | term()}
  def acknowledge do
    case status() do
      {:recorded, _} -> {:error, :already_recorded}
      :none -> record("manual", Vault.key!())
    end
  end

  defp record(method, key) do
    record = %{
      recorded_at: DateTime.utc_now() |> DateTime.truncate(:second),
      method: method,
      fingerprint: fingerprint(key)
    }

    body =
      Jason.encode!(%{
        "recorded_at" => DateTime.to_iso8601(record.recorded_at),
        "method" => method,
        "fingerprint" => record.fingerprint
      })

    with :ok <- File.mkdir_p(Path.dirname(path())),
         :ok <- File.write(path(), body),
         :ok <- File.chmod(path(), 0o600) do
      {:ok, record}
    end
  end
end

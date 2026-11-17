defmodule Wardmast.Accounts.ServiceAccountKey do
  @moduledoc """
  A Google Cloud service-account JSON key, the `:service_account` credential of an
  `antigravity` account (bd-b2t0kw): what agy 1.5.9 signs in with when it runs with
  `AGY_ADC_AUTH=true` and `GOOGLE_APPLICATION_CREDENTIALS` naming the key file.

  Measured against agy 1.5.9 itself (offline: no network, no keyring, a fake key whose
  `token_uri` pointed at a local stand-in): with `AGY_ADC_AUTH` on, agy loads Application
  Default Credentials the way Go's `golang.org/x/oauth2/google` does
  (`GOOGLE_APPLICATION_CREDENTIALS`, then `$HOME/.config/gcloud/application_default_credentials.json`),
  trades a JWT signed with the key for an access token at the key's `token_uri`, takes
  the Google Cloud project from `GOOGLE_CLOUD_QUOTA_PROJECT` or else the key's own
  `project_id`, and calls Vertex AI at `GOOGLE_CLOUD_LOCATION` (default `global`). So the
  key alone is enough: no project or location has to be configured beside it.

  `validate/1` checks the shape only (a JSON object of `type: "service_account"` with a
  `project_id`, a `client_email` and a `private_key`); whether Google accepts the key is
  only known when agy uses it. Nothing here ever returns or logs a value of the key:
  errors name the missing field.
  """

  @required ~w(project_id client_email private_key)
  @max_bytes 16_384

  @type reason ::
          :not_json
          | :not_json_object
          | :not_a_service_account
          | :too_large
          | {:missing_field, String.t()}

  @doc "`{:ok, json}` (the bytes as given) when `json` is a service-account key."
  @spec validate(term()) :: {:ok, String.t()} | {:error, {:invalid_service_account_key, reason()}}
  def validate(json) when is_binary(json) and byte_size(json) > @max_bytes,
    do: invalid(:too_large)

  def validate(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = key} -> check(key, json)
      {:ok, _other} -> invalid(:not_json_object)
      {:error, _} -> invalid(:not_json)
    end
  end

  def validate(_other), do: invalid(:not_json)

  defp check(%{"type" => "service_account"} = key, json) do
    case Enum.find(@required, &blank?(Map.get(key, &1))) do
      nil -> {:ok, json}
      field -> invalid({:missing_field, field})
    end
  end

  defp check(_key, _json), do: invalid(:not_a_service_account)

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp invalid(reason), do: {:error, {:invalid_service_account_key, reason}}

  @doc """
  The strings a worker's output must never show for this key (`Wardmast.Redaction`):
  the file as written, and its `private_key` and `private_key_id` as a program that
  parsed it would print them. `[]` for anything that is not a key.
  """
  @spec secret_values(String.t() | nil) :: [String.t()]
  def secret_values(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = key} ->
        [
          json
          | for(
              field <- ~w(private_key private_key_id),
              value = key[field],
              is_binary(value) and value != "",
              do: value
            )
        ]

      _ ->
        []
    end
  end

  def secret_values(_), do: []

  @doc "What an operator is told about a refused key: the reason, never the key."
  @spec describe(reason()) :: String.t()
  def describe(:not_json), do: "the key is not JSON"
  def describe(:not_json_object), do: "the key is not a JSON object"

  def describe(:not_a_service_account),
    do: ~s[the key's "type" is not "service_account" (a user login is not one)]

  def describe(:too_large), do: "the key is larger than #{@max_bytes} bytes"
  def describe({:missing_field, field}), do: "the key has no #{inspect(field)}"
end

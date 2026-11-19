defmodule Wardmast.Mergers.Gitlab.Endpoint do
  @moduledoc """
  Where a GitLab instance lives and how to reach it, shared by the merger, the
  tracker and the bot-credential clients (#1521).

    * `base_url` — scheme + host + optional path prefix of the instance
      (`https://gitlab.example.com`, `http://gitlab.internal:8080/gitlab`).
      Defaults to `https://<host>`. Configured as `"base_url"` or `"api_url"`;
      a trailing `/api/v4` on the latter is accepted and stripped.
    * `ca_cacertfile` — path to a PEM CA bundle for an instance behind an
      internal CA. Passed as the TLS `cacertfile` in Req's `connect_options`.
      Unset: the system trust store, exactly as before.

  Config modules call `from_raw/1` / `ca_from_raw/1` while resolving; clients
  call `api_url/1` and `connect_options/1` on the resolved map.
  """

  @doc "The instance base URL (no trailing slash) for a resolved config/entry map."
  @spec base_url(map()) :: String.t()
  def base_url(%{base_url: url}) when is_binary(url) and url != "", do: trim(url)
  def base_url(%{host: host}), do: "https://#{host}"

  @doc "The REST API root, `<base_url>/api/v4`."
  @spec api_url(map()) :: String.t()
  def api_url(cfg), do: base_url(cfg) <> "/api/v4"

  @doc """
  Req `connect_options` carrying the configured CA bundle, or `[]` (the system
  trust store).
  """
  @spec connect_options(map()) :: keyword()
  def connect_options(%{ca_cacertfile: path}) when is_binary(path) and path != "",
    do: [transport_opts: [cacertfile: path]]

  def connect_options(_cfg), do: []

  @doc """
  `connect_options/1` as top-level Req options (`[connect_options: [...]]`, or
  `[]`), for callers that build a `Req` request directly rather than through
  `Wardmast.Http.Client`.
  """
  @spec req_options(map()) :: keyword()
  def req_options(cfg) do
    case connect_options(cfg) do
      [] -> []
      opts -> [connect_options: opts]
    end
  end

  @doc "The normalised base URL from a raw string-keyed config, or `nil` when unset."
  @spec from_raw(map()) :: String.t() | nil
  def from_raw(raw) when is_map(raw) do
    case present(Map.get(raw, "base_url")) || present(Map.get(raw, "api_url")) do
      nil -> nil
      url -> url |> trim() |> String.replace_suffix("/api/v4", "") |> trim()
    end
  end

  @doc "The CA bundle path from a raw string-keyed config, or `nil` when unset."
  @spec ca_from_raw(map()) :: String.t() | nil
  def ca_from_raw(raw) when is_map(raw), do: present(Map.get(raw, "ca_cacertfile"))

  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp present(_), do: nil

  defp trim(url), do: String.trim_trailing(url, "/")
end

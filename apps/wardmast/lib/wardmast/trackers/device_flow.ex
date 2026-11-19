defmodule Wardmast.Trackers.DeviceFlow do
  @moduledoc """
  OAuth 2.0 device authorization grant (RFC 8628) for the GitHub and GitLab
  trackers, so an operator can authorise Wardmast from the dashboard instead of
  pasting a personal access token.

  The flow:

    1. `start/2` asks the provider for a device + user code. The UI shows the
       `user_code` and `verification_uri` to the operator.
    2. `await/2` polls the token endpoint every `interval` seconds until the
       operator approves, denies, or the code expires. It honours `slow_down`
       by lengthening the interval, as the RFC requires.
    3. The caller stores the returned token as a `secret:` entry — this module
       never persists, logs or inspects it.

  ## Client IDs

  Device flow needs an OAuth app's client ID (no secret — that is the point of
  the flow). It comes from the `:client_id` option, else
  `config :wardmast, :github_oauth_client_id` / `:gitlab_oauth_client_id`, else
  the `WARDMAST_GITHUB_OAUTH_CLIENT_ID` / `WARDMAST_GITLAB_OAUTH_CLIENT_ID`
  environment variable. Wardmast ships none: register an OAuth app on the
  provider (GitHub: enable "Device Flow"; GitLab 17.2+: a non-confidential
  application with the `api` scope).

  ## Hosts

  GitHub uses `https://github.com`, or — when the tracker's `base_url` points at
  a GitHub Enterprise API — that server's host. GitLab uses the tracker's
  `host` (or `base_url`), defaulting to `https://gitlab.com`.

  In `:test`, `:wardmast, :github_http_stub` routes every request through
  `Req.Test` under `#{inspect(__MODULE__)}.HTTP`.
  """

  @grant_type "urn:ietf:params:oauth:grant-type:device_code"
  @default_interval 5
  @stub_name Wardmast.Trackers.DeviceFlow.HTTP

  # `device_code` is a bearer secret while the flow is open, and flow structs end
  # up in LiveView assigns and async results that crash dumps inspect — so it
  # (and the client id) never print.
  @derive {Inspect, only: [:provider, :user_code, :verification_uri, :expires_in, :interval]}
  @enforce_keys [:provider, :client_id, :token_url, :device_code, :user_code, :verification_uri]
  defstruct [
    :provider,
    :client_id,
    :token_url,
    :device_code,
    :user_code,
    :verification_uri,
    :verification_uri_complete,
    expires_in: 900,
    interval: @default_interval
  ]

  @type provider :: :github | :gitlab

  @type t :: %__MODULE__{
          provider: provider(),
          client_id: String.t(),
          token_url: String.t(),
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          verification_uri_complete: String.t() | nil,
          expires_in: pos_integer(),
          interval: pos_integer()
        }

  @type failure :: :expired | :denied | {:provider, String.t()} | {:network, String.t()}

  @doc "Providers that support the device flow."
  @spec providers() :: [provider()]
  def providers, do: [:github, :gitlab]

  @doc "Whether `type` (a tracker type string or atom) can use the device flow."
  @spec supported?(term()) :: boolean()
  def supported?(type) when type in ["github", "gitlab", :github, :gitlab], do: true
  def supported?(_), do: false

  @doc """
  The OAuth client ID that would be used for `provider`, or `nil` when none is
  configured. Never returns a secret — client IDs are public identifiers.
  """
  @spec configured_client_id(provider()) :: String.t() | nil
  def configured_client_id(provider) do
    blank_to_nil(Application.get_env(:wardmast, :"#{provider}_oauth_client_id")) ||
      blank_to_nil(
        System.get_env("WARDMAST_#{provider |> to_string() |> String.upcase()}_OAUTH_CLIENT_ID")
      )
  end

  @doc """
  Request a device + user code.

  Options: `:client_id` (override), `:tracker_config` (the workspace's
  `tracker.config` map, for the host), `:scope` (override the default).
  """
  @spec start(provider(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def start(provider, opts \\ []) when provider in [:github, :gitlab] do
    tracker_config = Keyword.get(opts, :tracker_config) || %{}

    with {:ok, client_id} <- client_id(provider, opts[:client_id]) do
      base = base_url(provider, tracker_config)

      params = [client_id: client_id, scope: Keyword.get(opts, :scope, default_scope(provider))]

      case post(base <> device_path(provider), params) do
        {:ok, %{"device_code" => dc, "user_code" => uc, "verification_uri" => uri} = body}
        when is_binary(dc) and is_binary(uc) and is_binary(uri) ->
          {:ok,
           %__MODULE__{
             provider: provider,
             client_id: client_id,
             token_url: base <> token_path(provider),
             device_code: dc,
             user_code: uc,
             verification_uri: uri,
             verification_uri_complete: string_or_nil(body["verification_uri_complete"]),
             expires_in: positive_int(body["expires_in"], 900),
             interval: positive_int(body["interval"], @default_interval)
           }}

        {:ok, %{"error" => _} = body} ->
          {:error, provider_message(body)}

        {:ok, _other} ->
          {:error, "#{label(provider)} returned an unexpected device-code response"}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  @doc """
  Poll the token endpoint once.

    * `{:ok, token}` — approved.
    * `:pending` — the operator has not acted yet.
    * `{:slow_down, flow}` — poll less often; `flow.interval` is the new pace.
    * `{:error, :expired | :denied | {:provider, msg} | {:network, msg}}`.
  """
  @spec poll(t()) ::
          {:ok, String.t()} | :pending | {:slow_down, t()} | {:error, failure()}
  def poll(%__MODULE__{} = flow) do
    params = [client_id: flow.client_id, device_code: flow.device_code, grant_type: @grant_type]

    case post(flow.token_url, params) do
      {:ok, %{"access_token" => token}} when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %{"error" => "authorization_pending"}} ->
        :pending

      {:ok, %{"error" => "slow_down"} = body} ->
        {:slow_down, %{flow | interval: positive_int(body["interval"], flow.interval + 5)}}

      {:ok, %{"error" => "expired_token"}} ->
        {:error, :expired}

      {:ok, %{"error" => "access_denied"}} ->
        {:error, :denied}

      {:ok, %{"error" => _} = body} ->
        {:error, {:provider, provider_message(body)}}

      {:ok, _other} ->
        {:error, {:provider, "#{label(flow.provider)} returned an unexpected token response"}}

      {:error, message} ->
        {:error, {:network, message}}
    end
  end

  @doc """
  Poll until approved, denied or expired. Blocks the caller (run it in a Task /
  `start_async`).

  The lifetime is tracked by summing the sleeps rather than reading the clock,
  so a test with a no-op `:sleep` runs instantly. Options:

    * `:sleep` — `(ms -> any)`, default `Process.sleep/1`.
    * `:on_tick` — `(t() -> any)`, called before each sleep (progress hook).
  """
  @spec await(t(), keyword()) :: {:ok, String.t()} | {:error, failure()}
  def await(%__MODULE__{} = flow, opts \\ []) do
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    on_tick = Keyword.get(opts, :on_tick, fn _ -> :ok end)
    do_await(flow, sleep, on_tick, 0)
  end

  defp do_await(flow, sleep, on_tick, elapsed_ms) do
    case poll(flow) do
      {:ok, _token} = ok ->
        ok

      {:error, _} = err ->
        err

      :pending ->
        wait(flow, sleep, on_tick, elapsed_ms)

      {:slow_down, flow} ->
        wait(flow, sleep, on_tick, elapsed_ms)
    end
  end

  defp wait(flow, sleep, on_tick, elapsed_ms) do
    wait_ms = flow.interval * 1000

    if elapsed_ms + wait_ms > flow.expires_in * 1000 do
      {:error, :expired}
    else
      on_tick.(flow)
      sleep.(wait_ms)
      do_await(flow, sleep, on_tick, elapsed_ms + wait_ms)
    end
  end

  @doc "An operator-facing sentence for a failed flow."
  @spec describe_error(failure(), provider()) :: String.t()
  def describe_error(:expired, provider),
    do: "The #{label(provider)} code expired before it was approved. Start again for a new code."

  def describe_error(:denied, provider),
    do: "Authorization was denied on #{label(provider)}. Start again if that was a mistake."

  def describe_error({:provider, msg}, provider), do: "#{label(provider)} said: #{msg}"

  def describe_error({:network, msg}, provider),
    do: "Could not reach #{label(provider)}: #{msg}"

  # ---- internals -----------------------------------------------------------

  defp client_id(provider, override) do
    case blank_to_nil(override) || configured_client_id(provider) do
      nil ->
        {:error,
         "No #{label(provider)} OAuth client ID is configured. Enter one, or set " <>
           "WARDMAST_#{provider |> to_string() |> String.upcase()}_OAUTH_CLIENT_ID."}

      id ->
        {:ok, id}
    end
  end

  defp default_scope(:github), do: "repo"
  defp default_scope(:gitlab), do: "api"

  defp device_path(:github), do: "/login/device/code"
  defp device_path(:gitlab), do: "/oauth/authorize_device"

  defp token_path(:github), do: "/login/oauth/access_token"
  defp token_path(:gitlab), do: "/oauth/token"

  defp label(:github), do: "GitHub"
  defp label(:gitlab), do: "GitLab"

  defp base_url(:github, config) do
    case blank_to_nil(config["base_url"]) do
      nil ->
        "https://github.com"

      api_url ->
        uri = URI.parse(api_url)

        if uri.host in [nil, "api.github.com"],
          do: "https://github.com",
          else: "#{uri.scheme || "https"}://#{uri.host}#{port_suffix(uri)}"
    end
  end

  defp base_url(:gitlab, config) do
    raw = blank_to_nil(config["base_url"]) || blank_to_nil(config["host"]) || "gitlab.com"
    raw = if String.contains?(raw, "://"), do: raw, else: "https://" <> raw
    String.trim_trailing(raw, "/")
  end

  defp port_suffix(%URI{port: port, scheme: scheme})
       when port in [nil, 80, 443] or is_nil(scheme),
       do: ""

  defp port_suffix(%URI{port: port}), do: ":#{port}"

  # Both providers answer errors as an `error` field — GitHub with HTTP 200,
  # GitLab with 400 — so the status is deliberately ignored and the body decides.
  defp post(url, params) do
    opts =
      [
        url: url,
        method: :post,
        form: params,
        headers: [{"accept", "application/json"}, {"user-agent", "wardmast"}],
        receive_timeout: 15_000,
        retry: false,
        decode_body: :json
      ]
      |> Keyword.merge(stub_opts())

    case Req.request(opts) do
      {:ok, %Req.Response{body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, "unexpected HTTP #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp stub_opts do
    if Application.get_env(:wardmast, :github_http_stub, false),
      do: [plug: {Req.Test, @stub_name}],
      else: []
  end

  defp provider_message(%{"error_description" => d}) when is_binary(d) and d != "", do: d
  defp provider_message(%{"error" => e}) when is_binary(e), do: e
  defp provider_message(_), do: "unknown error"

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_, default), do: default

  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp blank_to_nil(_), do: nil
end

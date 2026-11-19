defmodule Wardmast.Screenshots.Capture.Shooter.Chromium do
  @moduledoc """
  The built-in `Wardmast.Screenshots.Capture.Shooter`: one headless Chromium run per image
  (`$ARB_CHROME`, which the worker image sets; `chromium` on `PATH` otherwise).

  It asks the app for the route first (`GET`, no redirects followed beyond the browser's own) to
  learn the HTTP status, because the Chromium CLI does not report it: 404 means "absent at this
  commit", any other 4xx/5xx is a route error. It then screenshots at the viewport's size and
  device scale factor with the theme's colour scheme, timezone UTC and `en-US`.

  This shooter only does what a command line can: a route, a viewport, a colour scheme and a theme
  `query`. A shot that needs steps, `wait_for`, a `target` element, `full_page`, `hide`, a login or
  a theme `local_storage` returns `{:error, {:shot, reason}}` naming what it cannot do rather than a
  picture that quietly lacks it. Those need the CDP runner of the design's N1; plug it in as another
  `Shooter`.

  `ctx[:chrome]` overrides the browser path (a test seam).
  """

  @behaviour Wardmast.Screenshots.Capture.Shooter

  @impl true
  def shoot(spec) do
    with :ok <- supported(spec),
         {:ok, chrome} <- chrome(spec),
         :ok <- check_status(url(spec)) do
      run(chrome, spec)
    end
  end

  @doc false
  @spec unsupported(map()) :: [String.t()]
  def unsupported(%{entry: entry, theme: theme, config: config}) do
    [
      {entry.steps != [], "steps"},
      {entry.wait_for != nil, "wait_for"},
      {entry.target != nil, "target"},
      {entry.full_page, "full_page"},
      {entry.hide != [], "hide"},
      {entry.as != nil or config.login["kind"] not in [nil, "none"], "login"},
      {map_size(Map.get(theme, "local_storage") || %{}) > 0, "the theme's local_storage"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp supported(spec) do
    case unsupported(spec) do
      [] ->
        :ok

      what ->
        {:error,
         {:shot,
          "#{spec.entry.id} needs #{Enum.join(what, ", ")}, which the command-line Chromium " <>
            "shooter cannot do (it needs the CDP capture runner)"}}
    end
  end

  defp chrome(spec) do
    override = if is_map(spec.ctx), do: spec.ctx[:chrome]
    found = override || System.get_env("ARB_CHROME") || System.find_executable("chromium")

    if found && File.exists?(found),
      do: {:ok, found},
      else: {:error, {:shot, "no headless Chromium found (set ARB_CHROME)"}}
  end

  defp url(spec) do
    query = Map.get(spec.theme, "query") || %{}
    base = spec.base_url <> spec.path

    if map_size(query) == 0 do
      base
    else
      sep = if String.contains?(base, "?"), do: "&", else: "?"
      base <> sep <> URI.encode_query(query)
    end
  end

  defp check_status(url) do
    case Req.get(url, retry: false, receive_timeout: 10_000, connect_options: [timeout: 5_000]) do
      {:ok, %{status: status}} when status < 400 -> :ok
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, {:shot, "GET #{url}: #{Exception.message(exception)}"}}
    end
  end

  @doc false
  @spec argv(map(), String.t()) :: [String.t()]
  def argv(spec, profile_dir) do
    vp = spec.viewport

    [
      "--headless=new",
      "--no-sandbox",
      "--disable-gpu",
      "--hide-scrollbars",
      "--lang=en-US",
      "--user-data-dir=#{profile_dir}",
      "--force-device-scale-factor=#{vp["device_scale_factor"] || 1}",
      "--window-size=#{vp["width"]},#{vp["height"]}",
      "--virtual-time-budget=5000",
      "--blink-settings=preferredColorScheme=#{if spec.theme["color_scheme"] == "dark", do: 1, else: 0}",
      "--screenshot=#{spec.out_file}",
      url(spec)
    ]
  end

  defp run(chrome, spec) do
    profile =
      Path.join(
        Path.dirname(spec.out_file),
        ".chrome-profile-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(profile)
    {exec, args} = with_timeout(chrome, argv(spec, profile), spec.timeout_s)

    try do
      case System.cmd(exec, args, stderr_to_stdout: true, env: [{"TZ", "UTC"}]) do
        {_out, 0} -> :ok
        {out, code} -> {:error, {:shot, "chromium exited with status #{code}: #{tail(out)}"}}
      end
    after
      File.rm_rf(profile)
    end
  end

  defp with_timeout(chrome, args, seconds) do
    case System.find_executable("timeout") do
      nil -> {chrome, args}
      timeout -> {timeout, ["#{seconds}", chrome | args]}
    end
  end

  defp tail(out), do: out |> String.trim() |> String.slice(-500, 500)
end

defmodule Wardmast.Screenshots.Capture.Shooter.Chromium do
  @moduledoc """
  The built-in `Wardmast.Screenshots.Capture.Shooter`: one headless Chromium run per image
  (`$ARB_CHROME`, which the worker image sets; `chromium` on `PATH` otherwise), inside the
  capture's sandbox.

  It asks the app for the route first (`GET` through the sandbox's `reach/1`, reading only the
  status) to learn the HTTP status, because the Chromium CLI does not report it: 404 means
  "absent at this commit", any other 4xx/5xx is a route error. It then screenshots at the
  viewport's size and device scale factor with the theme's colour scheme, timezone UTC and
  `en-US`.

  The browser runs in a sandbox of its own (`Wardmast.Screenshots.Capture.Sandbox.browser/3`):
  no network but its bridge to the app, nothing of the host but the system directories and the
  browser's install directory, nothing writable but the shot's own directory (`spec.scratch`),
  and an environment built from nothing. The image is copied from there to `out_file` only when
  it is a regular file, so a page that took over the browser cannot get the server to read some
  other file in its place. A spec without a sandbox (or without the boot's `app`) starts no
  browser at all.

  ## Chromium's own sandbox is off (`--no-sandbox`)

  The capture sandbox is the boundary, and Chromium's would add nothing to it:

    * It does not start there. Chromium's namespace sandbox needs a user namespace nested inside
      the capture sandbox's, which hosts that restrict unprivileged user namespaces (Ubuntu's
      AppArmor policy, a container's seccomp profile: the podman worker container refuses
      `unshare --user`) do not allow, and its setuid helper cannot gain privileges under the
      `no_new_privs` bwrap sets. Keeping it would make capture fail on those hosts.
    * It protects the wrong thing here. It keeps a compromised renderer from the browser
      process, but that process holds nothing worth taking (a fresh profile per shot, no
      cookies, no credentials, an empty environment), and whoever wrote the page already runs
      arbitrary code as the app, in an equivalent sandbox. What must not be reachable from the
      page (the host's loopback, other hosts, the host's files) is out of reach because of the
      capture sandbox, not Chromium's.

  This shooter only does what a command line can: a route, a viewport, a colour scheme and a theme
  `query`. A shot that needs steps, `wait_for`, a `target` element, `full_page`, `hide`, a login or
  a theme `local_storage` returns `{:error, {:shot, reason}}` naming what it cannot do rather than a
  picture that quietly lacks it. Those go to `Shooter.Cdp` (the design's N1); `Shooter.Auto`, the
  capture step's default, sends each shot to whichever can do it, using `unsupported/1`.

  A shot also reports the page's text (`{:ok, %{text: texts}}`), which the capture step scans
  (`Wardmast.Screenshots.Capture.Safety`, bd-995svb): after the screenshot the same browser is run
  again to dump the DOM, and its text and `alt` / `title` values are what is reported.

  `ctx[:chrome]` overrides the browser path (a test seam).
  """

  @behaviour Wardmast.Screenshots.Capture.Shooter

  alias Wardmast.Screenshots.Capture.Safety
  alias Wardmast.Screenshots.Capture.Sandbox
  alias Wardmast.Worker.ReleaseEnv

  @impl true
  def shoot(spec) do
    with {:ok, sandbox, app} <- sandboxed(spec),
         :ok <- supported(spec),
         {:ok, chrome} <- chrome(spec),
         :ok <- check_status(url(spec), sandbox.reach(app)) do
      run(chrome, spec, sandbox, app)
    end
  end

  @doc false
  @spec sandboxed(map()) :: {:ok, module(), map()} | {:error, {:shot, String.t()}}
  def sandboxed(%{sandbox: sandbox, app: %{} = app, scratch: dir})
      when is_atom(sandbox) and not is_nil(sandbox) and is_binary(dir),
      do: {:ok, sandbox, app}

  def sandboxed(_spec) do
    {:error,
     {:shot,
      "no capture sandbox (or no booted app to reach) for the browser, and Chromium is never " <>
        "run unsandboxed"}}
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
            "shooter cannot do (it needs the CDP shooter; use Shooter.Auto)"}}
    end
  end

  @doc false
  @spec chrome(map()) :: {:ok, String.t()} | {:error, {:shot, String.t()}}
  def chrome(spec) do
    override = if is_map(spec.ctx), do: spec.ctx[:chrome]

    found =
      if override do
        if File.exists?(override), do: override
      else
        find_chrome()
      end

    if found,
      do: {:ok, found},
      else: {:error, {:shot, "no headless Chromium found (set ARB_CHROME)"}}
  end

  @candidates ~w(chromium chromium-browser google-chrome google-chrome-stable)

  @doc """
  The Chromium binary capture will use: `$ARB_CHROME`, else the first of `chromium`,
  `chromium-browser`, `google-chrome`, `google-chrome-stable` on `PATH`, else a Playwright
  cache build. `nil` when none exists. The three functions are injectable for tests.
  """
  @spec find_chrome(
          (String.t() -> String.t() | nil),
          (String.t() -> String.t() | nil),
          (String.t() -> boolean())
        ) :: String.t() | nil
  def find_chrome(
        env \\ &System.get_env/1,
        find \\ &System.find_executable/1,
        exists? \\ &File.exists?/1
      ) do
    explicit = env.("ARB_CHROME")

    cond do
      explicit -> if exists?.(explicit), do: explicit
      path = Enum.find_value(@candidates, find) -> if exists?.(path), do: path
      true -> playwright_cache(exists?)
    end
  end

  defp playwright_cache(exists?) do
    home = System.user_home() || ""

    [
      Path.join(home, ".cache/ms-playwright/chromium-*/chrome-linux*/chrome"),
      Path.join(home, ".cache/ms-playwright/chromium-*/chrome-linux*/headless_shell")
    ]
    |> Enum.flat_map(&(&1 |> Path.wildcard() |> Enum.sort(:desc)))
    |> Enum.find(exists?)
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

  defp check_status(url, reach) do
    opts = [retry: false, receive_timeout: 10_000, request_timeout: 20_000, into: &status_only/2]

    case Req.get(url, opts ++ reach) do
      {:ok, %{status: status}} when status < 400 -> :ok
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, {:shot, "GET #{url}: #{Exception.message(exception)}"}}
    end
  end

  # Only the status matters: an untrusted app's body is never read into the server, and
  # `request_timeout` bounds the whole exchange, so a trickled answer cannot hold the shot open.
  defp status_only({:data, _chunk}, acc), do: {:halt, acc}

  @doc false
  @spec argv(map(), String.t()) :: [String.t()]
  def argv(spec, profile_dir) do
    vp = spec.viewport

    [
      "--headless=new",
      # Chromium's own sandbox cannot start inside the capture sandbox on most hosts and would
      # guard nothing the capture sandbox does not; see the moduledoc and
      # docs/design/ui-screenshot-capture.md §2. Never run this argv outside `Sandbox.browser/3`.
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

  # `exec` is the operator-configured Chromium binary (or the `timeout`
  # binary found on PATH) and `args` is an argv list handed to
  # `ReleaseEnv.cmd/3` (a release-env-scrubbed `System.cmd/3`) directly, never
  # through a shell; the viewport/URL come from the worker's manifest but are
  # only ever argv elements, so they cannot inject a command. The browser
  # itself runs under `env -i` inside the capture sandbox.
  defp run(chrome, spec, sandbox, app) do
    dir = spec.scratch
    profile = Path.join(dir, "profile")
    home = Path.join(dir, "home")
    shot = Path.join(dir, "shot.png")
    Enum.each([profile, home], &File.mkdir_p!/1)

    try do
      with {:ok, boxed} <-
             boxed(sandbox, [chrome | argv(%{spec | out_file: shot}, profile)], app, dir) do
        env = [System.find_executable("env") || "/usr/bin/env", "-i" | browser_env(home)]
        {exec, args} = with_timeout(env ++ boxed, spec.timeout_s)

        case ReleaseEnv.cmd(exec, args, stderr_to_stdout: true) do
          {_out, 0} ->
            with :ok <- collect(shot, spec.out_file) do
              page_text(chrome, spec, profile, {sandbox, app, env})
            end

          {out, code} ->
            {:error, {:shot, "chromium exited with status #{code}: #{tail(out)}"}}
        end
      end
    after
      File.rm_rf(dir)
    end
  end

  # bd-995svb (design §9.5): the text the page shows, for the capture step's data-safety scan,
  # from a second run of the same browser in the same sandbox that dumps the DOM instead of
  # shooting it. Only the DOM's text and its `alt` / `title` values are kept
  # (`Capture.Safety.html_text/1`); a run that dumps nothing is a failed shot, never an unscanned one.
  defp page_text(chrome, spec, profile, {sandbox, app, env}) do
    argv = [chrome | dump_argv(spec, profile)]

    with {:ok, boxed} <- boxed(sandbox, argv, app, spec.scratch) do
      {exec, args} = (env ++ boxed) |> with_timeout(spec.timeout_s) |> discard_stderr()

      case ReleaseEnv.cmd(exec, args) do
        {html, 0} when html != "" ->
          {:ok, %{text: Safety.html_text(html)}}

        {_html, code} ->
          {:error, {:shot, "chromium could not dump the page's text (exit status #{code})"}}
      end
    end
  end

  # The browser's stderr (console and log lines can quote what the page shows) is thrown away
  # inside the child instead of inheriting the coordinator's own stderr and journal: only the DOM
  # on stdout is read, and only through the scan's text reduction. `exec "$@"` runs the argv as
  # given; nothing is parsed by the shell.
  defp discard_stderr({exec, args}),
    do: {"/bin/sh", ["-c", ~s(exec "$@" 2>/dev/null), "sh", exec | args]}

  # `argv/2` with the screenshot swapped for a DOM dump (the URL stays last).
  defp dump_argv(spec, profile) do
    {flags, [url]} = spec |> argv(profile) |> Enum.split(-1)
    Enum.reject(flags, &String.starts_with?(&1, "--screenshot=")) ++ ["--dump-dom", url]
  end

  defp boxed(sandbox, browser, app, dir) do
    case sandbox.browser(browser, app, [dir]) do
      {:ok, argv} ->
        {:ok, argv}

      {:error, reason} ->
        {:error,
         {:shot, "the capture sandbox could not start the browser: #{describe(sandbox, reason)}"}}
    end
  end

  @doc false
  @spec describe(module(), term()) :: String.t()
  def describe(sandbox, reason) do
    sandbox.describe(reason)
  rescue
    _ -> inspect(reason)
  end

  # Built from nothing, like the app's: the server's own environment (credentials, tokens,
  # database URLs) never reaches a process that renders the app's pages. TMPDIR is /tmp, never the
  # shot's directory: Chromium binds its singleton socket under TMPDIR, and the shot's deep path
  # is past the 108-byte limit of a Unix socket path (Chromium aborts: "Socket path too long").
  # In the bwrap sandbox /tmp is a private tmpfs of each browser.
  @doc false
  @spec browser_env(String.t()) :: [String.t()]
  def browser_env(home) do
    ["PATH=#{Sandbox.path()}", "HOME=#{home}", "TMPDIR=/tmp", "LANG=C.UTF-8", "TZ=UTC"]
  end

  # The image the browser left in its own directory, copied out only when it is a plain file. A
  # symlink there (to a host file the page wanted posted) is never followed: the shot simply has
  # no image, which the capture step reports.
  defp collect(shot, out_file) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(shot),
         {:ok, data} <- File.read(shot) do
      File.write!(out_file, data)
      :ok
    else
      _ -> {:error, {:shot, "the browser wrote no image"}}
    end
  end

  @doc false
  @spec with_timeout([String.t()], pos_integer()) :: {String.t(), [String.t()]}
  def with_timeout([exec | args], seconds) do
    case System.find_executable("timeout") do
      nil -> {exec, args}
      timeout -> {timeout, ["#{seconds}", exec | args]}
    end
  end

  @doc false
  @spec tail(String.t()) :: String.t()
  def tail(out), do: out |> String.trim() |> String.slice(-500, 500)
end

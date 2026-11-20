defmodule Wardmast.Screenshots.Capture.Sandbox do
  @moduledoc """
  Where a capture's untrusted code runs (bd-bhrsdv; design `docs/design/ui-screenshot-capture.md`
  §2, §9). Everything a capture boots comes from the repo at a commit the worker wrote: the app's
  setup, seed and start commands, and the pages the browser renders. None of it runs on the host
  as itself. A sandbox gives it:

    * **no network**: no route to the host's loopback (the coordinator on `:4848`, a database,
      another worker's dev server) or to any external host;
    * **no ambient filesystem**: the host's system directories read-only, the boot's own
      checkout and scratch writable, and nothing else (no home directory, no `/tmp`, no runtime
      sockets) unless the operator lists a read-only path (`screenshots.sandbox.readonly_paths`);
    * no view of the host's processes.

  The app is still reachable by the host (the readiness probe, the status check) and by the
  browser, through `expose/2`: the sandbox decides how (`reach/1` gives the `Req` options).

  ## Fail closed

  `Wardmast.Screenshots.Capture.run/2` asks `status/0` before it reads the plan or boots
  anything. A sandbox this host cannot provide is a **skip** (`{:skipped, {:no_sandbox,
  reason}}`, `reason` starting "capture needs a sandbox"), never an unsandboxed boot. There is no
  unsandboxed implementation in this codebase; the booter and the shooter refuse to run without
  one. The default is `Wardmast.Screenshots.Capture.Sandbox.Bwrap`.

  ## Callbacks

    * `status/0`: `:ok` when this host can run the sandbox, else `{:error, reason}`.
    * `describe/1`: `reason` in words, for the skip message.
    * `expose/2`: prepare to reach an app that will listen on `127.0.0.1:<port>` inside `box`;
      the returned `app` map (`:port` at least) goes to `command/3`, `browser/3`, `reach/1` and
      `release/1`.
    * `command/3`: the argv that runs `argv` (an app command, executable first) inside `box`.
      `app` is `nil` for a command that runs to completion (setup, seed) and the `expose/2`
      result for the app itself.
    * `browser/3`: the argv that runs the browser `argv` in a sandbox of its own that can reach
      `app` on `127.0.0.1:<port>` and nothing else, and write only the `writable` dirs.
    * `browser/4`: as `browser/3`, with `readonly` paths visible too (a directory, or a file such
      as a browser binary, whose directory is shown): for a runner that needs more of the host
      than its own executable's directory (the CDP shooter's `node_modules` and Chromium).
    * `reach/1`: the `Req` options that reach `app` from the host.
    * `release/1`: undo `expose/2` (a socket dir, say) once the app is stopped.
    * `fetch_command/2` (optional, bd-3glf2a): the argv that runs **trusted** code (the deps
      cache seed: a default-branch tree's `mix deps.get`) inside `box` with the network on. Never
      for anything a worker wrote. A sandbox without it cannot build the offline deps cache.

  A `box` may also carry (bd-3glf2a) `services`, the boot's service endpoints
  (`Wardmast.Screenshots.Capture.Services`): each `socket` is a host Unix socket that leads to the
  service, which an app command must reach on `127.0.0.1:<port>` (and at `sandbox_socket`, when
  set), and `cache_dirs`, directories shown read-only (the deps cache).

  The environment is not the sandbox's business: the caller always runs the argv under
  `env -i` with an environment built from nothing.
  """

  @typedoc "A service a boot's app commands reach (`Capture.Services.start/2`)."
  @type endpoint :: %{
          required(:name) => String.t(),
          required(:port) => :inet.port_number(),
          required(:socket) => String.t(),
          optional(:sandbox_socket) => String.t() | nil
        }

  @typedoc "One boot's directories: `checkout` and `scratch` are writable, the rest read-only."
  @type box :: %{
          required(:checkout) => String.t(),
          required(:scratch) => String.t(),
          optional(:readonly_paths) => [String.t()],
          optional(:services) => [endpoint()],
          optional(:cache_dirs) => [String.t()]
        }

  @typedoc "How the sandbox reaches a started app (`expose/2`)."
  @type app :: %{required(:port) => :inet.port_number(), optional(atom()) => term()}

  @callback status() :: :ok | {:error, term()}
  @callback describe(reason :: term()) :: String.t()
  @callback expose(box(), :inet.port_number()) :: {:ok, app()} | {:error, term()}
  @callback command(argv :: [String.t()], box(), app() | nil) ::
              {:ok, [String.t()]} | {:error, term()}
  @callback browser(argv :: [String.t()], app(), writable :: [String.t()]) ::
              {:ok, [String.t()]} | {:error, term()}
  @callback browser(
              argv :: [String.t()],
              app(),
              writable :: [String.t()],
              readonly :: [String.t()]
            ) :: {:ok, [String.t()]} | {:error, term()}
  @callback reach(app()) :: keyword()
  @callback release(app()) :: :ok
  @callback fetch_command(argv :: [String.t()], box()) :: {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks fetch_command: 2

  alias Wardmast.Worker.ReleaseEnv

  @doc "The sandbox `Capture.run/2` uses when the caller names none."
  @spec default() :: module()
  def default, do: Wardmast.Screenshots.Capture.Sandbox.Bwrap

  @doc """
  `:ok`, or `{:error, message}` where `message` is the skip reason: "capture needs a sandbox: "
  and what is missing. Never raises: a sandbox whose check crashes is unavailable.
  """
  @spec check(module()) :: :ok | {:error, String.t()}
  def check(sandbox) do
    case sandbox.status() do
      :ok -> :ok
      {:error, reason} -> {:error, "capture needs a sandbox: " <> describe(sandbox, reason)}
      other -> {:error, "capture needs a sandbox: #{inspect(sandbox)} answered #{inspect(other)}"}
    end
  rescue
    e ->
      {:error,
       "capture needs a sandbox: checking #{inspect(sandbox)} raised #{Exception.message(e)}"}
  catch
    kind, value ->
      {:error,
       "capture needs a sandbox: checking #{inspect(sandbox)} failed: #{inspect({kind, value})}"}
  end

  defp describe(sandbox, reason) do
    sandbox.describe(reason)
  rescue
    _ -> inspect(reason)
  end

  @doc """
  The `PATH` a sandboxed process gets: the VM's own with a release's `erts-*/bin` and `bin`
  removed (`ReleaseEnv` knows them), so `mix`/`elixir` in an app's command do not resolve `erl`
  from Wardmast's ERTS.
  """
  @spec path() :: String.t()
  def path do
    case List.keyfind(ReleaseEnv.port_env(), "PATH", 0) do
      {"PATH", path} when is_binary(path) -> path
      _ -> System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin"
    end
  end
end

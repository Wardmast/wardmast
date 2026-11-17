defmodule WardmastCli.Supervisor do
  @moduledoc """
  The seam between the CLI and the host's service manager.

  `arb restart`, `arb session list` and `arb install-service` all need to ask
  "is the server's unit managed here, stop/restart it, how is it doing, set it
  up at boot". On Linux that is systemd (`systemctl`/`loginctl`); no other
  call site may shell out to those tools directly. Everything goes through the
  module returned by `impl/0`, so a new backend (launchd on macOS is
  `WardmastCli.Supervisor.Launchd`) is a module implementing this behaviour,
  not an edit to every command.

  Callbacks return data, not process exits: the one place a failure message is
  worded is the backend that knows what the tool is called. Callers decide
  whether an error is fatal (`Output.die/2`).

  All spawning goes through `WardmastCli.Cmd.Start.run_cmd/3`, so tests keep
  using the `:bd2_cmd_runner` process-dictionary stub.
  """

  @typedoc "`:user` for a per-user service, `:system` for a machine-wide one."
  @type scope :: :user | :system

  @typedoc """
  Whether the backend manages the server's service unit:

    * `:managed`   — the unit exists and the manager answered.
    * `:not_found` — the manager positively says there is no such unit (or the
      manager is not installed at all).
    * `{:unreachable, why}` — the manager could not be asked.
  """
  @type service_state :: :managed | :not_found | {:unreachable, String.t()}

  @typedoc "Run state of the service unit; `invocation_id` changes on every start."
  @type service_info ::
          %{state: String.t(), invocation_id: String.t(), job: String.t() | nil} | nil

  @typedoc "A fatal-error message: `{title, detail}` as `Output.die/2` takes them."
  @type failure :: {String.t(), String.t()}

  @doc "Is the server's unit managed by this backend? (Read-only probe.)"
  @callback service_state() :: service_state()

  @doc "Directories where the unit file may live (for the fail-closed on-disk check)."
  @callback unit_dirs() :: [Path.t()]

  @doc "File name of the unit/plist inside `c:unit_dirs/0` (for the same on-disk check)."
  @callback unit_file_name() :: String.t()

  @doc "Stop the service. `{:error, message}` when the manager refused or is missing."
  @callback stop_service() :: :ok | {:error, String.t()}

  @doc """
  Enqueue a restart without waiting for it (`--no-block` on systemd: a
  blocking restart can hang on a wedged start job). The caller polls
  `c:service_info/0`.
  """
  @callback restart_service() :: :ok | {:error, String.t(), String.t()}

  @doc "Current state of the service unit, or `nil` when unreadable."
  @callback service_info() :: service_info()

  @doc "One recovery attempt for a start job that never ran. Failures are logged, not raised."
  @callback recover_stuck_service() :: :ok

  @doc """
  Raw listing of live units whose name starts with `prefix` (the
  `arb-session-*` scopes), or the die title/detail when the manager failed.
  """
  @callback list_scopes(prefix :: String.t()) ::
              {:ok, String.t()} | {:error, String.t(), String.t()}

  @doc "Re-read unit definitions. Dies on failure."
  @callback daemon_reload(scope()) :: :ok

  @doc "Enable the service and start it now. Dies on failure."
  @callback enable_now(scope()) :: :ok

  @doc "Idempotent stop + disable; whether the unit was actually disabled."
  @callback disable_now(scope()) :: boolean()

  @doc "Start the service at boot rather than first login. Non-fatal."
  @callback enable_boot_start() :: :enabled | :failed

  @doc "Enable (and start) a per-user timer unit. Raw `{output, exit_status}`."
  @callback enable_timer(unit :: String.t()) :: {String.t(), non_neg_integer()}

  @doc "Disable (and stop) a per-user timer unit. Raw `{output, exit_status}`."
  @callback disable_timer(unit :: String.t()) :: {String.t(), non_neg_integer()}

  @doc "Shell command an operator runs to inspect the service, echoed in output."
  @callback status_cmd(scope()) :: String.t()

  @doc "Shell command an operator runs to follow the service's logs, echoed in output."
  @callback logs_cmd(scope()) :: String.t()

  @doc ~S|Name of the service manager, for operator-facing messages (`"systemd"`, `"launchd"`).|
  @callback manager_name() :: String.t()

  @doc "Shell command an operator runs to restart the service."
  @callback restart_cmd() :: String.t()

  @doc "Shell command an operator runs to start the (stopped) service."
  @callback start_cmd() :: String.t()

  @doc "Shell command an operator runs to stop the service."
  @callback stop_cmd() :: String.t()

  @doc """
  Shell commands, in order, an operator runs to recover a service whose start
  never ran (the \"server is DOWN\" report).
  """
  @callback recover_cmds() :: [String.t()]

  @doc """
  The backend module for this host: launchd on macOS, systemd everywhere else.
  `config :wardmast_cli, :supervisor` overrides the choice.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:wardmast_cli, :supervisor) || impl_for(:os.type())

  @doc "The backend for an `:os.type/0` value."
  @spec impl_for({atom(), atom()}) :: module()
  def impl_for({:unix, :darwin}), do: WardmastCli.Supervisor.Launchd
  def impl_for(_os), do: WardmastCli.Supervisor.Systemd
end

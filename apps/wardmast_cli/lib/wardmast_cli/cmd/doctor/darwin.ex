defmodule WardmastCli.Cmd.Doctor.Darwin do
  @moduledoc """
  The macOS-only `arb server doctor` checks, and the list of Linux-only checks
  that are `n/a` there (bd-6tif6q §1.3, §6).

  The tool lookups and the PATH come from the *server*
  (`GET /api/server/platform`, `Wardmast.Doctor.Platform`): the PATH it hands its
  workers, with the Homebrew dirs appended, and where each tool resolves on it.
  They are never read from the doctor's own shell, which can differ from a
  launchd-started server's. tmux is not checked here; the server-side `tmux`
  check covers it.

  macOS has no bwrap, podman, cgroup, systemd linger or kernel OOM policy, so
  those checks report `n/a`. It also has no OS-level write jail or egress
  filter: write confinement is the agent's own permission layer
  (`:permission_layer`) and egress is `:none`. The doctor says so rather than
  implying a jail exists.
  """

  alias WardmastCli.Cmd.Doctor.Checks.Result

  @linux_only ~w(agy_write_jail agy_jail_escape agy_jail_reads agy_jail_network
                 agy_jail_keyring agy_ssh_transport egress_jail podman_sandbox
                 worker_memory worker_jail_unmask)

  @na_reason "not applicable on macOS: bwrap, podman, cgroups, systemd linger and the kernel OOM policy are Linux-only"

  @homebrew_dirs ["/opt/homebrew/bin", "/usr/local/bin"]

  @doc "Check ids that do not apply on macOS."
  @spec linux_only_ids() :: [String.t()]
  def linux_only_ids, do: @linux_only

  @doc "The `n/a` detail for a Linux-only check on macOS."
  @spec na_reason() :: String.t()
  def na_reason, do: @na_reason

  @doc "True for the darwin `:os.type/0` tuple."
  @spec darwin?({atom(), atom()}) :: boolean()
  def darwin?({:unix, :darwin}), do: true
  def darwin?(_), do: false

  @doc """
  The darwin checks. Options: `:path` (the server's captured PATH), `:tools`
  (`%{name => resolved path | nil}`, as the server reports them) and `:service`
  (`WardmastCli.Supervisor.Launchd.service_mode/0`, probed on this host; `nil`
  when the CLI is not on the macOS host, so the plists cannot be read).
  """
  @spec checks(keyword()) :: [Result.t()]
  def checks(opts \\ []) do
    path = Keyword.get(opts, :path, "")
    tools = Keyword.get(opts, :tools, %{})
    found = fn name -> Map.get(tools, name) end

    [
      tool(
        "darwin_gtimeout",
        "gtimeout",
        found.("gtimeout"),
        :warn,
        "macOS has no GNU `timeout`; workers use gtimeout",
        "brew install coreutils"
      ),
      homebrew_path(path),
      tool(
        "darwin_claude",
        "claude",
        found.("claude"),
        :fail,
        "the claude worker CLI",
        "Install the Claude CLI (e.g. `brew install claude-code`) and make sure its dir is on the server's PATH"
      ),
      tool("darwin_gh", "gh", found.("gh"), :warn, "GitHub CLI", "brew install gh"),
      tool("darwin_glab", "glab", found.("glab"), :warn, "GitLab CLI", "brew install glab"),
      tool(
        "darwin_mise",
        "mise",
        found.("mise"),
        :warn,
        "toolchain manager",
        "brew install mise"
      ),
      service_mode(Keyword.get(opts, :service)),
      log_rotation(Keyword.get(opts, :service), Keyword.get(opts, :rotator_path)),
      write_confinement(),
      egress()
    ]
    |> Enum.map(&%{&1 | group: :sandboxes})
  end

  # bd-6f5dmo: the server's LogRotator must watch the file launchd writes to.
  defp log_rotation(%{mode: mode, stdout_path: out} = svc, rotator)
       when mode in [:agent, :daemon, :both] and is_binary(out) and is_binary(rotator) do
    base = %Result{id: "darwin_log_rotation", name: "log rotation"}

    if Path.expand(out) == Path.expand(rotator) do
      %{base | status: :ok, detail: "the log rotator watches launchd's StandardOutPath (#{out})"}
    else
      %{
        base
        | status: :warn,
          detail:
            "the log rotator watches #{rotator} but the plist (#{svc.plist}) writes #{out}: the log never rotates",
          hint:
            "Re-run `ward install service` so the plist exports WARDMAST_SERVER_LOG, then restart the server."
      }
    end
  end

  defp log_rotation(_service, _rotator) do
    %Result{
      id: "darwin_log_rotation",
      name: "log rotation",
      status: :na,
      detail: "not probed: no readable launchd plist, or the server did not report its log path"
    }
  end

  defp tool(id, name, found, missing_status, why, fix) do
    case found do
      nil ->
        %Result{
          id: id,
          name: name,
          status: missing_status,
          detail: "`#{name}` not found on the captured PATH (#{why})",
          hint: fix,
          blocks_readiness: false
        }

      file ->
        %Result{id: id, name: name, status: :ok, detail: "#{file} (#{why})"}
    end
  end

  defp homebrew_path(path) do
    dirs = String.split(path, ":", trim: true)

    case Enum.reject(@homebrew_dirs, &(&1 in dirs)) do
      [] ->
        %Result{
          id: "darwin_homebrew_path",
          name: "Homebrew PATH",
          status: :ok,
          detail: "captured PATH includes #{Enum.join(@homebrew_dirs, " and ")}"
        }

      missing ->
        %Result{
          id: "darwin_homebrew_path",
          name: "Homebrew PATH",
          status: :warn,
          detail:
            "captured PATH lacks #{Enum.join(missing, ", ")}; a launchd-started server has a minimal PATH",
          hint: "Add the Homebrew dirs to the PATH in the service environment, then restart."
        }
    end
  end

  # Agent (per-user, free tier) vs daemon (system-wide, team Mac), read from the
  # plists on disk by `Supervisor.Launchd.service_mode/0`.
  defp service_mode(nil) do
    %Result{
      id: "darwin_service_mode",
      name: "launchd mode",
      status: :na,
      detail:
        "not probed: this CLI is not on the macOS host running the server, so its launchd plists cannot be read"
    }
  end

  defp service_mode(%{mode: :none}) do
    %Result{
      id: "darwin_service_mode",
      name: "launchd mode",
      status: :na,
      detail:
        "no launchd job installed (server started by hand?); `ward install service` adds one"
    }
  end

  defp service_mode(%{mode: :agent} = svc) do
    %Result{
      id: "darwin_service_mode",
      name: "launchd mode",
      status: :ok,
      detail:
        "agent mode: per-user LaunchAgent (#{svc.plist}), runs as the logged-in user and starts at login"
    }
  end

  defp service_mode(%{mode: :both} = svc) do
    %Result{
      id: "darwin_service_mode",
      name: "launchd mode",
      status: :warn,
      detail:
        "both a LaunchAgent and a LaunchDaemon (#{svc.plist}) are installed: two servers would fight over one port",
      hint:
        "Keep one: `ward install service --uninstall` (agent) or `sudo ward install service --system --uninstall` (daemon)."
    }
  end

  defp service_mode(%{mode: :daemon} = svc) do
    base = %Result{id: "darwin_service_mode", name: "launchd mode", status: :ok}

    case daemon_problem(svc) do
      nil ->
        %{
          base
          | detail:
              "daemon mode: system-wide LaunchDaemon (#{svc.plist}), starts at boot and runs as #{svc.user}"
        }

      {detail, hint} ->
        %{base | status: :warn, detail: "daemon mode (#{svc.plist}): " <> detail, hint: hint}
    end
  end

  defp daemon_problem(%{user: user}) when user in [nil, "", "root"] do
    {"no unprivileged UserName, so launchd would run the server as root",
     "Re-run `sudo ward install service --system --service-user <dedicated account>`."}
  end

  defp daemon_problem(%{owner_uid: uid}) when is_integer(uid) and uid != 0 do
    {"the plist is not root-owned, so launchd will refuse to load it",
     "sudo chown root:wheel the plist, or re-run `sudo ward install service --system`."}
  end

  defp daemon_problem(%{file_mode: mode}) when is_integer(mode) do
    if Bitwise.band(mode, 0o022) != 0 do
      {"the plist is group/world-writable (mode #{Integer.to_string(mode, 8)}), so launchd will refuse to load it",
       "sudo chmod 644 the plist, or re-run `sudo ward install service --system`."}
    end
  end

  defp daemon_problem(_), do: nil

  defp write_confinement do
    %Result{
      id: "darwin_write_confinement",
      name: "write confinement",
      status: :warn,
      detail:
        "permission_layer: macOS has no OS write jail, so file writes are unconfined at the OS level; only the agent's own permission/deny rules limit them",
      hint: "Run untrusted workloads on a Linux node (bwrap or podman) instead."
    }
  end

  defp egress do
    %Result{
      id: "darwin_egress",
      name: "egress confinement",
      status: :warn,
      detail:
        "none: macOS has no egress jail, so network egress is unconfined; an egress allowlist is not enforced",
      hint: "Run workloads that need an egress allowlist on a Linux node."
    }
  end
end

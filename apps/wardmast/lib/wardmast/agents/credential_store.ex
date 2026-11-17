defmodule Wardmast.Agents.CredentialStore do
  @moduledoc """
  Where does each agent CLI keep its login on this host, and can Arbiter read it?
  (MAC P4-5)

  Arbiter's credential handling was written against Linux:

    * **Claude** keeps its interactive OAuth grant in
      `<config dir>/.credentials.json`. Mode B session seeding
      (`Wardmast.Agents.Claude.ConfigDir.seed_credentials/2`) *copies* that file.
    * **agy** keeps its Google grant in the freedesktop Secret Service, reached
      over D-Bus. The keyring is scoped to the OS user session, not `$HOME`, so
      the isolated `$HOME` of `Wardmast.Agents.Gemini.ConfigDir` does not hide it.

  Neither holds on macOS. Claude Code stores its grant in the **login Keychain**
  (generic password `Claude Code-credentials`) and writes no `.credentials.json`
  unless that file already exists from an older install. agy has no D-Bus on a
  Mac, so its Secret Service probe can never succeed; it uses the Keychain too.

  The Keychain is user-scoped like the Secret Service, so a redirected `$HOME`
  or `CLAUDE_CONFIG_DIR` does not hide it from the CLI itself. What Arbiter
  *cannot* do is read it: there is no file to copy, and shelling out to
  `security find-generic-password -w` raises a Keychain ACL dialog nobody is at
  the keyboard to answer. `detect/2` therefore reports `arbiter_readable?:
  false` with a `:warning` naming the consequence, instead of letting mode B
  silently seed nothing and the session open on a login screen.

  > **D3, unverified here.** The Keychain service name and the "no
  > `.credentials.json` on macOS" behaviour are external CLI behaviour, not
  > checked on a Mac from this repo (CI's macOS job runs a tagged subset only).
  > Detection is deliberately conservative: the presence of a credentials file
  > always wins over the OS guess, and nothing here reads the Keychain.

  Every function takes `:os` (an `:os.type/0` tuple) so both platforms are
  testable on any host.
  """

  require Logger

  @type agent :: :claude | :agy
  @type store :: :file | :keychain | :secret_service

  @type t :: %{
          agent: agent(),
          store: store(),
          arbiter_readable?: boolean(),
          warning: String.t() | nil
        }

  @credentials_file ".credentials.json"

  @doc """
  Classify `agent`'s credential store on this host.

  Options: `:os` (default `:os.type()`), and for `:claude` `:source_dir` (the
  operator's config dir; default `Wardmast.Agents.Claude.ConfigDir.source_dir/0`).
  """
  @spec detect(agent(), keyword()) :: t()
  def detect(agent, opts \\ [])

  def detect(:claude, opts) do
    if darwin?(opts) and not credentials_file?(source_dir(opts)) do
      %{
        agent: :claude,
        store: :keychain,
        arbiter_readable?: false,
        warning:
          "Claude Code on macOS keeps its login in the Keychain, not in a " <>
            "#{@credentials_file}, so mode B (seeded_credentials) has nothing to copy and " <>
            "the session would open signed-out. Arbiter does not read the Keychain. " <>
            "Use mode A (a setup token: `claude setup-token`, attached to the workspace's " <>
            "Claude account) instead."
      }
    else
      %{agent: :claude, store: :file, arbiter_readable?: true, warning: nil}
    end
  end

  def detect(:agy, opts) do
    if darwin?(opts) do
      %{
        agent: :agy,
        store: :keychain,
        arbiter_readable?: false,
        warning:
          "agy on macOS authenticates through the login Keychain, which Arbiter cannot " <>
            "read or seed. agy workers rely on the operator having signed in with `agy` on " <>
            "this Mac; a Keychain that is locked (an SSH or launchd session without the " <>
            "login keychain unlocked) will end in an interactive prompt."
      }
    else
      %{agent: :agy, store: :secret_service, arbiter_readable?: false, warning: nil}
    end
  end

  @doc """
  Whether `agent`'s credential store is usable on this host (agy only).

  macOS: the `security` CLI is on `PATH` (`:security_cli` stubs it). Elsewhere:
  `:secret_service` (a boolean stub) or `Wardmast.Worker.Jail.keyring_usable?/0`.
  """
  @spec available?(:agy, keyword()) :: boolean()
  def available?(:agy, opts \\ []) do
    cond do
      darwin?(opts) -> Keyword.get_lazy(opts, :security_cli, &security_cli?/0)
      Keyword.has_key?(opts, :secret_service) -> Keyword.fetch!(opts, :secret_service)
      true -> Wardmast.Worker.Jail.keyring_usable?()
    end
  end

  @doc "Whether this host's agy store is a freedesktop Secret Service (any non-macOS host)."
  @spec secret_service?(keyword()) :: boolean()
  def secret_service?(opts \\ []), do: not darwin?(opts)

  @doc "Log `detect/2`'s warning (if any) and return the detection."
  @spec warn(agent(), keyword()) :: t()
  def warn(agent, opts \\ []) do
    detection = detect(agent, opts)
    if detection.warning, do: Logger.warning("[credential-store] #{detection.warning}")
    detection
  end

  defp darwin?(opts), do: match?({:unix, :darwin}, Keyword.get_lazy(opts, :os, &:os.type/0))

  defp security_cli?, do: System.find_executable("security") != nil

  defp source_dir(opts) do
    Keyword.get_lazy(opts, :source_dir, &Wardmast.Agents.Claude.ConfigDir.source_dir/0)
  end

  defp credentials_file?(nil), do: false
  defp credentials_file?(dir), do: File.regular?(Path.join(dir, @credentials_file))
end

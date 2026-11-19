defmodule Wardmast.Agents.CliDetection do
  @moduledoc """
  Is each provider's CLI installed, where, and is it new enough (bd-5wfsj7).

  `detect/2` answers for one provider (`claude`, `codex`, `antigravity` — agy or
  the upstream gemini CLI), `detect_all/1` for all of them. The verdict:

    * `:ok` — installed and at or above the provider's minimum supported version;
    * `:missing` — not on the server's `PATH`; `action: :install`;
    * `:outdated` — below the minimum; `action: :upgrade`, `detail` names the
      required version;
    * `:unknown_version` — found, but its `--version` gave no number (or no answer
      in time). Not refused: an unreadable version is not evidence of an old one.

  The lookup walks the same `PATH` a worker spawn sees (the server's `PATH` plus,
  on macOS, the Homebrew baseline dirs, `Wardmast.Worker.SpawnEnv.darwin_baseline_path/3`),
  so what the Providers page and `ward server doctor` report is what a spawn
  resolves. When the server was launched from a GUI, `Wardmast.Boot.LoginShellPath`
  has already widened that `PATH` at boot.

  `gate/2` is dispatch's check: an `:outdated` CLI is refused with a reason that
  names the installed and the required version. A missing CLI is left to
  `Wardmast.Agents.Preflight` (`executable_not_found`), which already refuses it.

  The install and upgrade commands are the vendors' documented ones. They are
  **text for the operator to copy**: nothing here, or anywhere in the dashboard,
  runs an installer.

  Versions come from `Wardmast.Agents.HarnessVersion` (the binary asked
  `--version`, cached against its size/mtime/inode). Minimums can be overridden
  with `config :wardmast, #{inspect(__MODULE__)}, min_versions: %{"codex" => "…"}`;
  `enforce: false` and `probe: false` (the test config) turn the dispatch gate and the
  `--version` probe off so the suite never runs a real agent CLI; `path:` pins the
  searched `PATH`.
  """

  alias Wardmast.Agents.HarnessVersion
  alias Wardmast.Worker.SpawnEnv

  @type status :: :ok | :missing | :outdated | :unknown_version
  @type t :: %{
          provider: String.t(),
          label: String.t(),
          binary: String.t() | nil,
          path: String.t() | nil,
          version: String.t() | nil,
          min_version: String.t() | nil,
          status: status(),
          action: :install | :upgrade | nil,
          install_command: String.t(),
          upgrade_command: String.t(),
          docs_url: String.t(),
          detail: String.t()
        }

  # Floors chosen against the versions this harness was built and probed with
  # (claude stream-json/`--permission-mode`, codex-cli 0.153.4, agy 1.5.9, gemini
  # CLI 0.45.0 — see the adapters' moduledocs); overridable by config.
  @specs [
    %{
      provider: "claude",
      label: "Claude Code",
      binaries: ["claude"],
      min_versions: %{"claude" => "2.0.0"},
      install: "npm install -g @anthropic-ai/claude-code",
      upgrade: "claude update",
      docs: "https://docs.claude.com/en/docs/claude-code/setup"
    },
    %{
      provider: "codex",
      label: "Codex",
      binaries: ["codex"],
      min_versions: %{"codex" => "0.100.0"},
      install: "npm install -g @openai/codex",
      upgrade: "npm install -g @openai/codex@latest",
      docs: "https://developers.openai.com/codex/cli/"
    },
    %{
      provider: "antigravity",
      label: "Antigravity (agy / gemini)",
      binaries: ["agy", "gemini"],
      min_versions: %{"agy" => "1.5.0", "gemini" => "0.45.0"},
      install: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
      upgrade: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
      docs: "https://antigravity.google/docs/cli/install"
    }
  ]

  @doc "The providers detection covers, in display order."
  @spec providers() :: [String.t()]
  def providers, do: Enum.map(@specs, & &1.provider)

  @doc """
  Detect one provider's CLI. Options: `:path` (the `PATH` to search; default the
  server's, with the darwin baseline), `:min_versions` (`%{binary => version}`
  overrides), `:probe` (ask `--version`; default `true`, config `probe: false`
  turns it off).
  """
  @spec detect(String.t() | atom(), keyword()) :: t()
  def detect(provider, opts \\ []) do
    spec = spec!(provider)
    path = Keyword.get_lazy(opts, :path, fn -> config(:path) || search_path() end)
    mins = Map.merge(spec.min_versions, configured_mins(spec, opts))

    case find(spec.binaries, path) do
      nil -> missing(spec, mins)
      {binary, exe} -> found(spec, binary, exe, mins[binary], opts)
    end
  end

  @doc "`detect/2` for every provider."
  @spec detect_all(keyword()) :: [t()]
  def detect_all(opts \\ []), do: Enum.map(providers(), &detect(&1, opts))

  @doc """
  Dispatch's check for `provider`: `:ok`, or `{:error, {:cli_version, provider,
  phrase}}` when the CLI is below its minimum. Providers with no spec (grok, qwen)
  and every other verdict pass. `enforce: false` (config or option) is a no-op.
  """
  @spec gate(String.t() | atom() | nil, keyword()) ::
          :ok | {:error, {:cli_version, String.t(), String.t()}}
  def gate(provider, opts \\ []) do
    with true <- Keyword.get_lazy(opts, :enforce, &enforce?/0),
         name when is_binary(name) <- normalize(provider),
         %{status: :outdated, detail: detail} <- detect(name, opts) do
      {:error, {:cli_version, name, "held — " <> detail}}
    else
      _ -> :ok
    end
  end

  @doc "Whether dotted version `version` is at or above `minimum` (prerelease tags ignored)."
  @spec at_least?(String.t(), String.t()) :: boolean()
  def at_least?(version, minimum), do: key(version) >= key(minimum)

  @doc "The provider name a spec is keyed by (`agy`/`gemini` → `antigravity`), or `nil`."
  @spec normalize(String.t() | atom() | nil) :: String.t() | nil
  def normalize(provider) do
    case to_string(provider || "") do
      p when p in ["gemini", "agy", "antigravity"] -> "antigravity"
      p when p in ["claude", "codex"] -> p
      _ -> nil
    end
  end

  # ---- internals --------------------------------------------------------------

  defp spec!(provider) do
    name = normalize(provider) || raise ArgumentError, "no CLI spec for #{inspect(provider)}"
    Enum.find(@specs, &(&1.provider == name))
  end

  defp enforce?, do: config(:enforce) != false

  defp config(key), do: :wardmast |> Application.get_env(__MODULE__, []) |> Keyword.get(key)

  defp configured_mins(spec, opts) do
    from_config =
      :wardmast |> Application.get_env(__MODULE__, []) |> Keyword.get(:min_versions, %{})

    Map.merge(from_config, Keyword.get(opts, :min_versions, %{}))
    |> Map.take(spec.binaries)
  end

  defp search_path do
    base = System.get_env("PATH")
    {path, _} = SpawnEnv.darwin_baseline_path(base, :os.type(), System.get_env("HOME"))
    path || ""
  end

  defp find(binaries, path) do
    Enum.find_value(binaries, fn binary ->
      case find_executable(binary, path) do
        nil -> nil
        exe -> {binary, exe}
      end
    end)
  end

  defp find_executable(name, path) do
    path
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable?/1)
  end

  defp executable?(file) do
    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp base(spec) do
    %{
      provider: spec.provider,
      label: spec.label,
      binary: nil,
      path: nil,
      version: nil,
      min_version: nil,
      install_command: spec.install,
      upgrade_command: spec.upgrade,
      docs_url: spec.docs
    }
  end

  defp missing(spec, mins) do
    names = Enum.join(spec.binaries, " or ")

    Map.merge(base(spec), %{
      status: :missing,
      action: :install,
      min_version: mins[hd(spec.binaries)],
      detail: "#{spec.label} CLI (#{names}) is not installed on the server's PATH"
    })
  end

  defp found(spec, binary, exe, min, opts) do
    version =
      if Keyword.get_lazy(opts, :probe, fn -> config(:probe) != false end),
        do: HarnessVersion.host(spec.provider, probe: true, executable: exe)

    row = %{base(spec) | binary: binary, path: exe, version: version, min_version: min}
    verdict(row, spec)
  end

  defp verdict(%{version: nil} = row, spec),
    do:
      Map.merge(row, %{
        status: :unknown_version,
        action: nil,
        detail: "#{spec.label} CLI found at #{row.path} but its version could not be read"
      })

  defp verdict(%{version: version, min_version: min} = row, spec) do
    if min == nil or at_least?(version, min) do
      Map.merge(row, %{
        status: :ok,
        action: nil,
        detail: "#{spec.label} CLI #{version} at #{row.path}"
      })
    else
      Map.merge(row, %{
        status: :outdated,
        action: :upgrade,
        detail:
          "#{spec.label} CLI #{version} at #{row.path} is below the minimum supported " <>
            "version #{min}; upgrade it (`#{spec.upgrade}`)"
      })
    end
  end

  defp key(version) do
    core = version |> String.trim_leading("v") |> String.split(["-", "+"], parts: 2) |> hd()

    parts =
      core
      |> String.split(".")
      |> Enum.map(fn p ->
        case Integer.parse(p) do
          {n, _} -> n
          :error -> 0
        end
      end)

    (parts ++ [0, 0, 0]) |> Enum.take(max(length(parts), 3))
  end
end

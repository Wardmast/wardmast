defmodule Arbiter.Trackers.GitHub.Config do
  @moduledoc """
  Reads the GitHub Issues tracker configuration from the active workspace.

  ## Resolution order

    1. Process dict (`put_active/1`) — set by request lifecycles or tests.
    2. `Application.get_env(:arbiter, :github_tracker_default_config)` — a
       static fallback for tools that don't carry a workspace (e.g. a CLI
       escript or a Mix task seeded from env vars).
    3. Neither → `{:error, %Error{kind: :config_missing}}`.

  Mirrors `Arbiter.Trackers.Jira.Config` and `Arbiter.Mergers.Github.Config` —
  the tracker adapter is workspace-scoped, so it resolves owner / repo /
  credentials the same way.

  ## Shape

  Read from `workspace.config["tracker"]["config"]` (the adapter is selected by
  `workspace.config["tracker"]["type"] == "github"`):

      %{
        "owner" => "ryanrborn",
        "repo" => "arbiter",
        "credentials_ref" => "env:GITHUB_TOKEN",
        # optional:
        "base_url" => "https://api.github.com",
        "status_map" => %{
          "open" => %{"state" => "open"},
          "in_progress" => %{"state" => "open", "label" => "in progress"},
          "closed" => %{"state" => "closed"}
        }
      }

  ## `status_map`

  GitHub Issues have only two native states — `"open"` and `"closed"` — so the
  tracker-vocabulary `:in_progress` is expressed as an *open* issue carrying a
  label. Each tracker status maps to a `%{state: ..., label: ...}` pair:

    * `state` is `"open"` or `"closed"` (anything else falls back to the
      default for that status).
    * `label` is an optional GitHub label name (`nil` for none). On
      `transition/2` the adapter swaps the managed status labels — it adds the
      target's label and removes the other statuses' labels, leaving unrelated
      labels untouched.

  A workspace may write each entry as the full map above, or as a bare state
  string (`"closed" => "closed"`), which is read as `%{state: "closed",
  label: nil}`. An *absent* status inherits the full default; a *present* entry
  is taken exactly as written (an absent label means "no label", not the
  default). Defaults: open → open/no-label, in_progress → open/"in progress",
  closed → closed/no-label.

  `credentials_ref` is a small DSL: `"env:NAME"` looks up `System.get_env/1`.
  A bare string (no prefix) is treated as a literal token, but this should be
  avoided outside of tests.

  ## Which token (bd-43sydg)

  Mirrors the merger (`Arbiter.Mergers.Github.Config`, bd-bsmkfu). When the repo
  has a `git_credentials.repos.<repo>` entry of kind `github_app`, every tracker
  call carries the App's installation token, minted for the tracker's own
  `owner/repo` with issues:write, pull_requests:write and metadata:read only, and
  the limiter accounts those calls to the installation's pool (`:pool`). The repo
  is the one `override_repo/2` named, else the one the tracker's `owner/repo`
  slug matches. A repo with no such entry uses `credentials_ref`, as before. A
  `github_app` entry whose token cannot be minted is a `:config_missing` error,
  never a fallback to `credentials_ref`.

  With an App, `credentials_ref` is optional. It is only the *personal identity*
  (`identity_token`): an App cannot be an assignee, so "issues assigned to the
  workspace user" needs a person. When it is absent the claim set is the open
  issues carrying `"claim_label"` (default `"arbiter"`) instead
  (`claim_label` in the resolved config; `nil` otherwise) and the responses that
  list or sync issues say so (`Arbiter.Trackers.GitHub.claim_filter/0`).
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.GitHub.Error
  alias Arbiter.Worker.GitCredential
  alias Arbiter.Worker.HostCredential

  @pdict_key {__MODULE__, :active_workspace_config}
  @host_key "__host_credential"
  @repo_key "__repo"
  @default_claim_label "arbiter"

  @default_base_url "https://api.github.com"

  @default_status_map %{
    open: %{state: "open", label: nil},
    in_progress: %{state: "open", label: "in progress"},
    closed: %{state: "closed", label: nil}
  }

  @valid_states ~w(open closed)

  @type status_entry :: %{state: String.t(), label: String.t() | nil}

  @type config :: %{
          base_url: String.t(),
          owner: String.t(),
          repo: String.t(),
          token: String.t(),
          pool: {:installation, String.t()} | nil,
          identity_token: String.t() | nil,
          claim_label: String.t() | nil,
          status_map: %{atom() => status_entry}
        }

  @doc """
  Set the active GitHub tracker config for the current process. Accepts a
  `Workspace` (reads its `config["tracker"]["config"]`), a raw tracker-config
  map, or `nil` to clear.

  Idempotent; safe to call from request setup.
  """
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(nil) do
    Process.delete(@pdict_key)
    :ok
  end

  def put_active(%Workspace{config: config} = workspace) do
    tracker_config = get_in(config || %{}, ["tracker", "config"]) || %{}

    Process.put(
      @pdict_key,
      tracker_config
      |> CredentialsRef.embed_secrets(Workspace.secrets_map(workspace))
      |> Map.put(@host_key, workspace)
    )

    :ok
  end

  def put_active(%{} = tracker_config) do
    Process.put(@pdict_key, tracker_config)
    :ok
  end

  @doc """
  Merge a per-repo tracker config override over the current process's active
  config. Looks up `config["tracker"]["config"]["repos"][repo]` and, if present,
  merges it over the config seeded by `put_active/1` — so a workspace whose
  repos file issues to different `owner/repo` targets the right one. No-op when
  `repo` is nil/blank or the workspace declares no override for it. See
  `Arbiter.Trackers.ConfigOverride`.
  """
  @spec override_repo(Workspace.t() | nil, String.t() | nil) :: :ok
  def override_repo(workspace, repo) do
    :ok = Arbiter.Trackers.ConfigOverride.apply(@pdict_key, workspace, repo)

    # The repo whose `git_credentials` entry (a GitHub App) the token comes from.
    with %{} = active <- Process.get(@pdict_key),
         true <- is_binary(repo) and repo != "" do
      Process.put(@pdict_key, Map.put(active, @repo_key, repo))
    end

    :ok
  end

  @doc "Clear the per-process active config."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  @doc """
  Resolve the active GitHub tracker config into a fully-populated struct (with
  the token already looked up from env). Returns `{:ok, config}` or
  `{:error, %Error{kind: :config_missing}}`.
  """
  @spec resolve() :: {:ok, config} | {:error, Error.t()}
  def resolve do
    raw = active_raw()

    with {:ok, owner} <- fetch_string(raw, "owner"),
         {:ok, repo} <- fetch_string(raw, "repo"),
         {:ok, credential} <- credential(raw, owner, repo) do
      {:ok,
       Map.merge(credential, %{
         base_url: stringy(Map.get(raw, "base_url")) || @default_base_url,
         owner: owner,
         repo: repo,
         status_map: status_map(raw)
       })}
    end
  end

  @doc """
  The label that stands in for "assigned to me" when the tracker authenticates
  as a GitHub App with no personal `credentials_ref` (see the moduledoc), or
  `nil` when assignment is the claim identity. Does not mint a token.
  """
  @spec claim_label() :: String.t() | nil
  def claim_label do
    raw = active_raw()

    with {:ok, owner} <- fetch_string(raw, "owner"),
         {:ok, repo} <- fetch_string(raw, "repo"),
         {:app, _repo_key} <- app_repo(raw, owner, repo),
         {:error, _} <- fetch_token(raw) do
      claim_label_of(raw)
    else
      _ -> nil
    end
  end

  @doc "Same as resolve/0 but raises on missing config (for callers that prefer fail-fast)."
  @spec resolve!() :: config | no_return
  def resolve! do
    case resolve() do
      {:ok, cfg} -> cfg
      {:error, %Error{message: msg}} -> raise ArgumentError, msg
    end
  end

  @doc """
  Returns the active `"owner/repo"` slug, or nil if none is configured. Useful
  for building links and parsing refs without a full resolve.
  """
  @spec active_repo_slug() :: String.t() | nil
  def active_repo_slug do
    raw = Process.get(@pdict_key) || Application.get_env(:arbiter, :github_tracker_default_config)

    case raw do
      %{"owner" => owner, "repo" => repo} when is_binary(owner) and is_binary(repo) ->
        "#{owner}/#{repo}"

      _ ->
        nil
    end
  end

  # ---- Internals ----------------------------------------------------------

  defp active_raw do
    Process.get(@pdict_key) ||
      Application.get_env(:arbiter, :github_tracker_default_config) ||
      %{}
  end

  # The token every tracker call carries, and the personal identity (if any).
  defp credential(raw, owner, repo) do
    case app_repo(raw, owner, repo) do
      {:app, repo_key} ->
        app_credential(raw, repo_key, "#{owner}/#{repo}")

      :none ->
        with {:ok, token} <- fetch_token(raw) do
          {:ok, %{token: token, pool: nil, identity_token: token, claim_label: nil}}
        end
    end
  end

  defp app_credential(raw, repo_key, slug) do
    workspace = Map.fetch!(raw, @host_key)

    case HostCredential.tracker_credential(workspace, repo_key, remote: slug) do
      {:ok, %{token: token, pool: pool}} ->
        personal = personal_token(raw)

        {:ok,
         %{
           token: token,
           pool: pool,
           identity_token: personal,
           claim_label: if(is_nil(personal), do: claim_label_of(raw))
         }}

      {:ok, nil} ->
        {:error, config_missing("GitHub tracker repo #{repo_key} has no GitHub App credential")}

      {:error, reason} ->
        {:error,
         config_missing(
           "the scoped GitHub App token for repo #{repo_key} is unavailable: " <>
             HostCredential.format_error(reason)
         )}
    end
  end

  # `{:app, repo_key}` when the tracker's repo has a `github_app` entry in the
  # workspace's `git_credentials`: the repo `override_repo/2` named, else the one
  # the `owner/repo` slug matches. Anything else uses `credentials_ref`.
  defp app_repo(%{@host_key => workspace} = raw, owner, repo) do
    [Map.get(raw, @repo_key), "#{owner}/#{repo}"]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.find_value(:none, fn candidate ->
      match?(
        {:ok, %GitCredential{mode: :scoped, entry: %{kind: :github_app}}},
        GitCredential.plan(workspace, candidate)
      ) && {:app, candidate}
    end)
  end

  defp app_repo(_raw, _owner, _repo), do: :none

  # With an App the personal token is optional: absent, unset or unresolvable, it
  # is simply no personal identity.
  defp personal_token(raw) do
    case fetch_token(raw) do
      {:ok, token} -> token
      {:error, _} -> nil
    end
  end

  defp claim_label_of(raw), do: label(Map.get(raw, "claim_label")) || @default_claim_label

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        {:error,
         %Error{
           kind: :config_missing,
           status: nil,
           message:
             "GitHub tracker config missing #{inspect(key)}. Set workspace.config[\"tracker\"][\"config\"][#{inspect(key)}] or :arbiter, :github_tracker_default_config in Application env.",
           raw: nil
         }}
    end
  end

  # Resolve the token via the shared credentials_ref DSL (env: / secret: /
  # literal), mapping its tagged failures onto the tracker's config_missing error.
  defp fetch_token(raw) do
    case CredentialsRef.resolve(Map.get(raw, "credentials_ref"), raw) do
      {:ok, token} ->
        {:ok, token}

      {:env_unset, name} ->
        {:error, config_missing("GitHub tracker credentials env var #{inspect(name)} is unset")}

      {:secret_not_found, key} ->
        {:error,
         config_missing("GitHub tracker secret #{inspect(key)} is not set on the workspace")}

      {:external_error, _ref, _reason} = failure ->
        {:error, config_missing(CredentialsRef.describe_failure(failure))}

      :missing ->
        {:error, config_missing("GitHub tracker config missing \"credentials_ref\"")}
    end
  end

  defp config_missing(message) do
    %Error{kind: :config_missing, status: nil, message: message, raw: nil}
  end

  defp status_map(raw) do
    user = Map.get(raw, "status_map") || %{}

    Enum.into(@default_status_map, %{}, fn {atom_key, default} ->
      {atom_key, status_entry(Map.get(user, Atom.to_string(atom_key)), default)}
    end)
  end

  # A user entry can be a full map (%{"state" => ..., "label" => ...}), a bare
  # state string ("closed"), or absent (use the default). A *present* entry is
  # taken exactly as written — only an absent status inherits the default —
  # so an invalid/missing state in a present entry still falls back to the
  # default state, but an absent label means "no label" (not the default).
  defp status_entry(nil, default), do: default

  defp status_entry(state, default) when is_binary(state) do
    %{state: valid_state(state, default.state), label: nil}
  end

  defp status_entry(%{} = entry, default) do
    %{
      state: valid_state(Map.get(entry, "state"), default.state),
      label: label(Map.get(entry, "label"))
    }
  end

  defp status_entry(_, default), do: default

  defp valid_state(state, _fallback) when state in @valid_states, do: state
  defp valid_state(_state, fallback), do: fallback

  defp label(v) when is_binary(v) and v != "", do: v
  defp label(_v), do: nil

  defp stringy(nil), do: nil
  defp stringy(v) when is_binary(v), do: v
  defp stringy(_), do: nil
end

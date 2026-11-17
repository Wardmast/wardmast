defmodule Wardmast.Preview.Config do
  @moduledoc """
  The per-repo app-preview config (`worker.preview`, `worker.repos.<repo>.preview`).

  A repo's preview block starts its app from a ticket's checkout on a port
  Wardmast allocates (`Wardmast.Preview`). It resolves like the other per-repo
  `worker.*` keys: `worker.repos.<repo>.preview` is deep-merged over the
  workspace-level `worker.preview` (`Wardmast.Worker.SeedPaths.effective/2`).

      {"worker": {"repos": {"arbiter": {"preview": {
        "command": "mix phx.server",
        "setup": "mix deps.get && mix ecto.setup",
        "env": {"DATABASE_PATH": "/tmp/preview-{{task_id}}.sqlite3"},
        "ready_path": "/", "ready_timeout": 120
      }}}}}

  Keys:

    * `command` — the startup script, run from the checkout root. Required to
      start a preview; `{{port}}` etc. are substituted.
    * `setup` — optional, run once per preview checkout before the first start.
    * `port_env` — the variable set to the allocated port (default `PORT`).
    * `env` — extra variables; values are templated.
    * `ready_path` (default `/`) and `ready_timeout` (seconds, default 60) — the
      health probe that must answer before the URL is reported.
    * `port_range` — `"lo-hi"` or `[lo, hi]` (default `31000-31999`); may not
      overlap the worker dev-server range (`Wardmast.Worker.DevServerEnv`).
    * `idle_ttl_seconds` — auto-stop after this long untouched (default 7200).

  Placeholders: `{{port}}`, `{{task_id}}`, `{{checkout}}`, `{{host}}`.
  """

  alias Wardmast.Tasks.Workspace.Changes.PatchConfig
  alias Wardmast.Worker.SeedPaths

  @keys ~w(command setup port_env env ready_path ready_timeout port_range idle_ttl_seconds)
  @placeholders ~w(port task_id checkout host)
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @default_range {31_000, 31_999}
  @default_ttl 7200
  @default_ready_timeout 60
  @max_ready_timeout 3600

  # `Wardmast.Worker.DevServerEnv`'s phash range (base 20_000, 10_000 wide).
  @worker_range {20_000, 29_999}

  @type t :: %{
          command: String.t(),
          setup: String.t() | nil,
          port_env: String.t(),
          env: %{String.t() => String.t()},
          ready_path: String.t(),
          ready_timeout: pos_integer(),
          port_range: {pos_integer(), pos_integer()},
          idle_ttl_seconds: pos_integer()
        }

  @doc "The worker dev-server port range the preview range may never overlap."
  @spec worker_range() :: {pos_integer(), pos_integer()}
  def worker_range, do: @worker_range

  @doc "The default preview port range."
  @spec default_range() :: {pos_integer(), pos_integer()}
  def default_range, do: @default_range

  @doc "The placeholders a command / env value may use."
  @spec placeholders() :: [String.t()]
  def placeholders, do: @placeholders

  @doc """
  Validate a preview block, returning a list of error messages (`[]` = valid).
  `label` is the config path, e.g. `"worker.repos.arbiter.preview"`.
  """
  @spec validate(term(), String.t()) :: [String.t()]
  def validate(block, label) when is_map(block) do
    unknown =
      case Map.keys(block) -- @keys do
        [] ->
          []

        keys ->
          [
            "#{label} has unknown key(s) #{Enum.join(Enum.sort(keys), ", ")} " <>
              "(expected #{Enum.join(@keys, ", ")})"
          ]
      end

    unknown ++
      Enum.flat_map(@keys, fn key ->
        case Map.fetch(block, key) do
          :error -> []
          {:ok, value} -> validate_key(key, value, "#{label}.#{key}")
        end
      end)
  end

  def validate(_block, label), do: ["#{label} must be a map"]

  defp validate_key(key, value, label) when key in ["command", "setup"] do
    if is_binary(value) and String.trim(value) != "",
      do: placeholder_errors(value, label),
      else: ["#{label} must be a non-empty string"]
  end

  defp validate_key("port_env", value, label) do
    if is_binary(value) and Regex.match?(@env_name, value),
      do: [],
      else: ["#{label} must be an environment variable name"]
  end

  defp validate_key("env", %{} = env, label) do
    Enum.flat_map(env, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        name_errors =
          if Regex.match?(@env_name, k),
            do: [],
            else: ["#{label} key #{inspect(k)} is not a valid environment variable name"]

        name_errors ++ placeholder_errors(v, "#{label}.#{k}")

      {k, _v} when is_binary(k) ->
        ["#{label}.#{k} must be a string"]

      {k, _v} ->
        ["#{label} key #{inspect(k)} is not a valid environment variable name"]
    end)
  end

  defp validate_key("env", _value, label), do: ["#{label} must be a map of strings"]

  defp validate_key("ready_path", value, label) do
    if is_binary(value) and String.starts_with?(value, "/"),
      do: [],
      else: ["#{label} must start with /"]
  end

  defp validate_key("ready_timeout", value, label) do
    cond do
      not (is_integer(value) and value > 0) -> ["#{label} must be a positive integer"]
      value > @max_ready_timeout -> ["#{label} must be at most #{@max_ready_timeout}"]
      true -> []
    end
  end

  defp validate_key("idle_ttl_seconds", value, label) do
    if is_integer(value) and value > 0, do: [], else: ["#{label} must be a positive integer"]
  end

  defp validate_key("port_range", value, label) do
    case parse_range(value) do
      {:ok, {lo, hi}} -> range_errors(lo, hi, label)
      :error -> [~s(#{label} must be "lo-hi" or [lo, hi] with lo <= hi)]
    end
  end

  defp range_errors(lo, hi, label) do
    {wlo, whi} = @worker_range

    cond do
      lo < 1024 or hi > 65_535 -> ["#{label} must lie within 1024-65535"]
      lo <= whi and hi >= wlo -> ["#{label} overlaps the worker dev-server range #{wlo}-#{whi}"]
      true -> []
    end
  end

  defp placeholder_errors(value, label) do
    ~r/\{\{\s*([^{}\s]*)\s*\}\}/
    |> Regex.scan(value)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.reject(&(&1 in @placeholders))
    |> Enum.uniq()
    |> Enum.map(&"#{label} uses unknown placeholder {{#{&1}}} (known: #{Enum.join(@placeholders, ", ")})")
  end

  defp parse_range([lo, hi]) when is_integer(lo) and is_integer(hi) and lo <= hi,
    do: {:ok, {lo, hi}}

  defp parse_range(value) when is_binary(value) do
    with [lo, hi] <- String.split(value, "-", parts: 2),
         {lo, ""} <- Integer.parse(String.trim(lo)),
         {hi, ""} <- Integer.parse(String.trim(hi)),
         true <- lo <= hi do
      {:ok, {lo, hi}}
    else
      _ -> :error
    end
  end

  defp parse_range(_), do: :error

  @doc """
  The effective preview config for `repo` in `workspace` (anything with a
  `:config` map). `{:error, :not_configured}` when no `command` is set,
  `{:error, {:invalid, [message]}}` for a hand-edited block that would not pass
  `validate/2`.
  """
  @spec resolve(term(), String.t() | nil) ::
          {:ok, t()} | {:error, :not_configured | {:invalid, [String.t()]}}
  def resolve(%{config: %{"worker" => %{} = worker}}, repo) do
    merged = merge(worker, repo)

    case validate(merged, "preview") do
      [] -> build(merged)
      errors -> {:error, {:invalid, errors}}
    end
  end

  def resolve(_workspace, _repo), do: {:error, :not_configured}

  defp merge(worker, repo) do
    base = Map.get(worker, "preview")
    base = if is_map(base), do: base, else: %{}

    case SeedPaths.effective(worker, repo) do
      %{"preview" => %{} = override} -> PatchConfig.deep_merge(base, override)
      _ -> base
    end
  end

  defp build(%{"command" => command} = block) do
    {:ok, range} = parse_range(Map.get(block, "port_range", "31000-31999"))

    {:ok,
     %{
       command: command,
       setup: Map.get(block, "setup"),
       port_env: Map.get(block, "port_env", "PORT"),
       env: Map.get(block, "env", %{}),
       ready_path: Map.get(block, "ready_path", "/"),
       ready_timeout: Map.get(block, "ready_timeout", @default_ready_timeout),
       port_range: range,
       idle_ttl_seconds: Map.get(block, "idle_ttl_seconds", @default_ttl)
     }}
  end

  defp build(_block), do: {:error, :not_configured}

  @doc "Substitute `{{port}}`, `{{task_id}}`, `{{checkout}}`, `{{host}}` in `template`."
  @spec render(String.t(), map()) :: String.t()
  def render(template, vars) when is_binary(template) do
    Regex.replace(~r/\{\{\s*([^{}\s]*)\s*\}\}/, template, fn whole, name ->
      case name do
        "port" -> to_string(Map.get(vars, :port))
        "task_id" -> to_string(Map.get(vars, :task_id))
        "checkout" -> to_string(Map.get(vars, :checkout))
        "host" -> to_string(Map.get(vars, :host, "127.0.0.1"))
        _ -> whole
      end
    end)
  end

  @doc "Parse a `port_range` value (string or `[lo, hi]`) — see `validate/2`."
  @spec parse_port_range(term()) :: {:ok, {pos_integer(), pos_integer()}} | :error
  def parse_port_range(value), do: parse_range(value)
end

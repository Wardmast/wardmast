defmodule Wardmast.Env do
  @moduledoc """
  The one place Wardmast reads operator-facing environment variables.

  The project was renamed from Arbiter to Wardmast (bd-42q5vm). Operator
  config used to live in `ARB_*` / `ARBITER_*` variables; it now lives in
  `WARDMAST_*`. For one release the old spellings keep working:

    1. `WARDMAST_<NAME>` wins when set.
    2. else `ARB_<NAME>`, then `ARBITER_<NAME>`, with a **one-time**
       deprecation warning per legacy variable per VM.

  Call sites always pass the *new* name (`Wardmast.Env.get("WARDMAST_DATA_HOME")`)
  and never spell a fallback themselves; deleting the shim next release is a
  change to this file only.

  Like `System.get_env/1`, a variable that is set but empty is a set value.

  ## What is deliberately not routed through here

  Variables the server *exports to* workers, pods and the `arb` CLI
  (`ARB_TOKEN`, `ARB_HOST`, `ARB_WORKSPACE`, `ARB_WORKER_BEAD_ID`,
  `ARB_SESSION_*`, `ARB_GIT_TOKEN`, `ARBITER_MCP_TOKEN`, the `ARB_NODE_*` /
  `ARB_BRIDGE_*` pod contract, ...) are a wire contract with the CLI, the MCP
  server, the Helm chart and install scripts — separate tickets own those.
  Renaming them here would break running workers against an older `arb`.

  `config/runtime.exs` runs before application code is available in a
  release, so it carries a small inlined copy of this precedence rule (see
  the `env` helper at its top). `Wardmast.EnvTest` pins both to the same
  behaviour.

  Dependency-free on purpose (lives in `:wardmast_release_env`), so the
  server and the escript can share it.
  """

  require Logger

  @prefix "WARDMAST_"
  @legacy_prefixes ["ARB_", "ARBITER_"]

  @doc "The deprecated spellings of a `WARDMAST_*` name, in lookup order."
  @spec legacy_names(String.t()) :: [String.t()]
  def legacy_names(@prefix <> rest), do: Enum.map(@legacy_prefixes, &(&1 <> rest))

  def legacy_names(name) do
    raise ArgumentError, "expected a #{@prefix}-prefixed variable name, got: #{inspect(name)}"
  end

  @doc """
  The value of `name` (a `WARDMAST_*` variable), falling back to its legacy
  spellings, else `default`.
  """
  @spec get(String.t(), String.t() | nil) :: String.t() | nil
  def get(name, default \\ nil) do
    case fetch(name) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Like `get/2`, reading from an explicit env map instead of the OS environment."
  @spec get_from(%{optional(String.t()) => String.t()}, String.t(), String.t() | nil) ::
          String.t() | nil
  def get_from(env, name, default \\ nil) when is_map(env) do
    case fetch_from(env, name) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "`{:ok, value}` when `name` or a legacy spelling is set, else `:error`."
  @spec fetch(String.t()) :: {:ok, String.t()} | :error
  def fetch(name), do: lookup(name, &System.get_env/1)

  @doc "Like `fetch/1`, reading from an explicit env map."
  @spec fetch_from(%{optional(String.t()) => String.t()}, String.t()) ::
          {:ok, String.t()} | :error
  def fetch_from(env, name) when is_map(env), do: lookup(name, &Map.get(env, &1))

  @doc "The value, or raises `System.EnvError` naming the new variable."
  @spec fetch!(String.t()) :: String.t()
  def fetch!(name) do
    case fetch(name) do
      {:ok, value} -> value
      :error -> raise System.EnvError, env: name
    end
  end

  @doc """
  `System.get_env/1` for a name that may or may not be a Wardmast variable: a
  `WARDMAST_*` name gets the legacy fallback, any other name (a user-chosen
  `env:` credential such as `GITHUB_TOKEN`) is read as-is.
  """
  @spec read(String.t()) :: String.t() | nil
  def read(@prefix <> _ = name), do: get(name)
  def read(name), do: System.get_env(name)

  @doc "Forget which deprecations were already logged. Test seam."
  @spec reset_warnings() :: :ok
  def reset_warnings do
    for {{__MODULE__, :warned, _} = key, _} <- :persistent_term.get(),
        do: :persistent_term.erase(key)

    :ok
  end

  defp lookup(@prefix <> _ = name, reader) do
    case reader.(name) do
      nil -> lookup_legacy(name, legacy_names(name), reader)
      value -> {:ok, value}
    end
  end

  defp lookup(name, _reader), do: legacy_names(name)

  defp lookup_legacy(_name, [], _reader), do: :error

  defp lookup_legacy(name, [legacy | rest], reader) do
    case reader.(legacy) do
      nil ->
        lookup_legacy(name, rest, reader)

      value ->
        warn_once(legacy, name)
        {:ok, value}
    end
  end

  # `:global.trans/3` serialises concurrent first readers, so "once" holds under
  # a boot-time stampede too. It only runs on the legacy path, and only until
  # the first warning lands.
  defp warn_once(legacy, name) do
    key = {__MODULE__, :warned, legacy}

    unless :persistent_term.get(key, false) do
      :global.trans(
        {key, self()},
        fn ->
          unless :persistent_term.get(key, false) do
            :persistent_term.put(key, true)

            Logger.warning(
              "#{legacy} is deprecated and will stop working in the next release; " <>
                "set #{name} instead (#{name} wins if both are set)"
            )
          end
        end,
        [node()]
      )
    end

    :ok
  end
end

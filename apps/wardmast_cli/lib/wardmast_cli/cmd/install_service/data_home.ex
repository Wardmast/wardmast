defmodule WardmastCli.Cmd.InstallService.DataHome do
  @moduledoc """
  The data home `arb install service` pins into the service definition
  (bd-56wi24), resolved once per install so the wrapper script, `wardmast.env`,
  the plist / unit and the server's database, pid and accounts all agree.

  A launchd job (and a systemd unit) runs with the real `HOME`, not the
  installing shell's environment, so a data home that is only *implied* by the
  installer's `ARB_HOME` / `HOME` is lost: the server derives its own from the
  runtime `HOME` and lands somewhere else. Release installs therefore always
  export `WARDMAST_DATA_HOME` (and the legacy `ARB_DATA_HOME`), even when it
  equals the default.

  Precedence for a **release** install, first match wins:

    1. `:explicit_env` — `WARDMAST_DATA_HOME` (legacy `ARB_DATA_HOME`) set in
       the installing shell;
    2. the `:bd2_arbiter_home` test seam (reported as `:default`);
    3. `:arb_home_release` — `ARB_HOME` set: `<ARB_HOME>/.wardmast`, or
       `ARB_HOME` itself when `current/` lives there;
    4. `:default` — `Wardmast.Env.data_home/0` (`$HOME/.wardmast`).

  A **dev** (source checkout) install keeps `ARB_HOME` meaning the checkout and
  never copies it into the data home: the data home is `Wardmast.Env.data_home/0`
  and is only *exported* when the operator set it explicitly (`explicit/0`).
  """

  alias WardmastCli.Cmd.InstallService.Unit
  alias WardmastCli.Supervisor.Launchd.Plist

  @type source :: :explicit_env | :arb_home_release | :default
  @type t :: %{path: String.t(), source: source()}

  @doc """
  The data home explicitly set in the installing shell (`WARDMAST_DATA_HOME`,
  else legacy `ARB_DATA_HOME`; empty counts as unset), expanded; or `nil`.
  """
  @spec explicit() :: String.t() | nil
  def explicit do
    ["WARDMAST_DATA_HOME", "ARB_DATA_HOME"]
    |> Enum.find_value(fn name ->
      case System.get_env(name) do
        value when value in [nil, ""] -> nil
        value -> Path.expand(value)
      end
    end)
  end

  @doc "Resolve the data home for an install of the checkout/release at `root`."
  @spec resolve(String.t()) :: t()
  def resolve(root) do
    if Unit.dev_checkout?(root), do: resolve_dev(), else: resolve_release(root)
  end

  @doc "Resolve for a release install (`ARB_HOME` may hold the release)."
  @spec resolve_release(String.t()) :: t()
  def resolve_release(root) do
    cond do
      path = explicit() ->
        %{path: path, source: :explicit_env}

      seam = Process.get(:bd2_arbiter_home) ->
        %{path: seam, source: :default}

      System.get_env("ARB_HOME") not in [nil, ""] ->
        %{path: arb_home_data(root), source: :arb_home_release}

      true ->
        %{path: Wardmast.Env.data_home(), source: :default}
    end
  end

  @doc "Resolve for a dev (checkout) install: never derived from `ARB_HOME`."
  @spec resolve_dev() :: t()
  def resolve_dev do
    case explicit() do
      nil -> %{path: Unit.arbiter_home_path(), source: :default}
      path -> %{path: path, source: :explicit_env}
    end
  end

  @doc "The JSON / text name of a source."
  @spec source_label(source()) :: String.t()
  def source_label(:explicit_env), do: "explicit env (WARDMAST_DATA_HOME)"
  def source_label(:arb_home_release), do: "ARB_HOME release"
  def source_label(:default), do: "default"

  # `<ARB_HOME>/.wardmast`, or `ARB_HOME` itself when `current/` lives there.
  defp arb_home_data(root) do
    nested = Path.join(root, ".wardmast")

    cond do
      File.exists?(Plist.release_bin(nested)) -> nested
      File.exists?(Plist.release_bin(root)) -> root
      true -> nested
    end
  end
end

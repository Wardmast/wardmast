defmodule Wardmast.Worker.Timeout do
  @moduledoc """
  One portable way to bound an external command.

  Resolution order: GNU `timeout`, then Homebrew's `gtimeout` (macOS ships
  neither by default), then an Elixir-side bound (`Task.yield/2` + shutdown),
  which returns `{"", 124}` on expiry like `timeout(1)`. The Elixir-side bound
  cannot SIGKILL a child that ignores the port closing, so it is the last
  resort, not the preferred path.
  """

  alias Wardmast.Worker.ReleaseEnv

  @type opts :: [find: (String.t() -> String.t() | nil), kill_after: pos_integer()]

  @doc "The resolved binary: `{:ok, path}` for `timeout`, else `gtimeout`, else `:none`."
  @spec resolve(opts()) :: {:ok, String.t()} | :none
  def resolve(opts \\ []) do
    find = Keyword.get(opts, :find, &System.find_executable/1)

    Enum.find_value(["timeout", "gtimeout"], :none, fn name ->
      case find.(name) do
        path when is_binary(path) -> {:ok, path}
        _ -> nil
      end
    end)
  end

  @doc "`argv` prefixed with the resolved binary and deadline; unchanged when none resolves."
  @spec wrap([String.t()], pos_integer(), opts()) :: [String.t()]
  def wrap(argv, seconds, opts \\ []) do
    case resolve(opts) do
      {:ok, bin} ->
        [
          bin,
          "--kill-after=#{Keyword.get(opts, :kill_after, 5)}s",
          Integer.to_string(seconds) | argv
        ]

      :none ->
        argv
    end
  end

  @doc """
  A shell-command prefix (trailing space included) for `sh -c` scripts, e.g.
  `exec \#{prefix}"$0"`; empty when no binary resolves (callers then rely on
  their own Elixir-side bound).
  """
  @spec shell_prefix(pos_integer(), opts()) :: String.t()
  def shell_prefix(seconds, opts \\ []) do
    case resolve(opts) do
      {:ok, bin} ->
        "'#{String.replace(bin, "'", "'\\''")}' -k #{Keyword.get(opts, :kill_after, 1)} #{seconds} "

      :none ->
        ""
    end
  end

  @doc """
  Runs `exe args` bounded to `seconds` via `ReleaseEnv.cmd/3`. Remaining `opts`
  (`:cd`, `:env`, `:stderr_to_stdout`, ...) pass through; `:find` and
  `:kill_after` configure resolution.
  """
  @spec cmd(String.t(), [String.t()], pos_integer(), keyword()) :: {String.t(), integer()}
  def cmd(exe, args, seconds, opts \\ []) do
    {own, cmd_opts} = Keyword.split(opts, [:find, :kill_after])

    case resolve(own) do
      {:ok, _} ->
        [bin | rest] = wrap([exe | args], seconds, own)
        ReleaseEnv.cmd(bin, rest, cmd_opts)

      :none ->
        task = Task.async(fn -> ReleaseEnv.cmd(exe, args, cmd_opts) end)

        case Task.yield(task, seconds * 1_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {"", 124}
        end
    end
  end
end

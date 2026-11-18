defmodule Wardmast.Test.FakePs do
  @moduledoc """
  A scripted `ps` for `Wardmast.MCP.OperatorProof`'s darwin checks
  (bd-5tg348): an injected process table instead of the host's, so the
  ancestry and session cases don't depend on whichever host runs the suite.

  `runner/2` returns the `:ps` function `OperatorProof.authorize/2` takes. It
  answers the single-pid, header-less queries the proof makes
  (`-o ppid= -p <pid>`, `-o comm= -p <pid>`, `-o uid= -p <pid>`) in the shape
  real `ps` prints them: right-aligned numbers and a trailing newline, and
  exit status 1 with no output for a pid that isn't in the table.

      table = %{1 => {0, "/sbin/launchd"}, 600 => {1, "Terminal"}, 601 => {600, "-zsh"}}
      ps = FakePs.runner(table, uid: 501)

  Every call is also sent to the process that built the runner as
  `{:fake_ps, args}`, so a test can assert on what was asked.

  Options:

    * `:uid` - what `-o uid=` reports for every pid in the table (default 501)
    * `:override` - `fn field, pid -> {output, status} | nil end`, consulted
      first (`field` is `"ppid="`, `"comm="` or `"uid="`); `nil` falls through
      to the table. This is how a test scripts a failure (`{"ps: boom\\n", 71}`)
      or garbage output for one pid.
  """

  @type table :: %{integer() => {ppid :: integer(), comm :: String.t()}}
  @type runner :: ([String.t()] -> {String.t(), non_neg_integer()})

  @spec runner(table(), keyword()) :: runner()
  def runner(table, opts \\ []) do
    uid = Keyword.get(opts, :uid, 501)
    override = Keyword.get(opts, :override, fn _field, _pid -> nil end)
    caller = self()

    fn args ->
      send(caller, {:fake_ps, args})
      field = Enum.find(args, &String.ends_with?(&1, "="))
      pid = pid_arg(args)
      override.(field, pid) || answer(Map.get(table, pid), field, uid)
    end
  end

  defp pid_arg(args) do
    ["-p", pid | _] = Enum.drop_while(args, &(&1 != "-p"))
    String.to_integer(pid)
  end

  defp answer(nil, _field, _uid), do: {"", 1}
  defp answer({ppid, _comm}, "ppid=", _uid), do: {pad(ppid), 0}
  defp answer({_ppid, comm}, "comm=", _uid), do: {comm <> "\n", 0}
  defp answer(_entry, "uid=", uid), do: {pad(uid), 0}

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 5) <> "\n"
end

defmodule WardmastCli.SessionSockets do
  @moduledoc """
  Where macOS coordinator-session sockets and pidfiles live, found without the
  server (bd-a1pnnv, MAC P3-1).

  `Wardmast.Sessions.Naming` puts them in `<socket_root>/sessions` where
  `socket_root` is `Wardmast.Config.Paths.socket_root/0`:
  `WARDMAST_SOCKET_ROOT`, or `/tmp/arb-<hash of the scratch root>`. This escript
  has no dependency on `:wardmast` and the hash depends on server-side config
  it cannot see, so it searches instead: `$WARDMAST_SOCKET_ROOT/sessions` first,
  then every `/tmp/arb-*/sessions` (private `0700` directories, so only this
  user's are readable). The `session-<id>.pid` file holds the tmux server pid
  and the socket path, one per line.
  """

  @doc "Candidate session directories, most specific first."
  @spec dirs() :: [String.t()]
  def dirs do
    explicit =
      case System.get_env("WARDMAST_SOCKET_ROOT") do
        root when is_binary(root) and root != "" -> [Path.join(root, "sessions")]
        _ -> []
      end

    Enum.uniq(explicit ++ Path.wildcard("/tmp/arb-*/sessions"))
  end

  @doc "The existing tmux socket for session `id`, if any directory has one."
  @spec find_socket(String.t()) :: {:ok, String.t()} | :error
  def find_socket(id) do
    dirs()
    |> Enum.map(&Path.join(&1, "session-#{id}.sock"))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @doc "`{session_id, tmux_server_pid}` for every well-formed `session-<id>.pid`."
  @spec pidfiles() :: [{String.t(), pos_integer()}]
  def pidfiles do
    for dir <- dirs(),
        path <- Path.wildcard(Path.join(dir, "session-*.pid")),
        "session-" <> rest = Path.basename(path),
        id = String.trim_trailing(rest, ".pid"),
        id != "",
        {:ok, contents} <- [File.read(path)],
        [pid_line | _] = String.split(contents, "\n", trim: true),
        {pid, ""} when pid > 0 <- [Integer.parse(String.trim(pid_line))] do
      {id, pid}
    end
  end
end

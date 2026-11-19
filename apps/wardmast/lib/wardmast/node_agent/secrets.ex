defmodule Wardmast.NodeAgent.Secrets do
  @moduledoc """
  Per-run secrets on a node (`docs/design/remote-workers.md` §7.1, §11; RW2/U13).

  `podman run -e NAME` writes the resolved value into the container's OCI
  `config.json` and podman's state DB on the **persistent** graph root, so a
  secret never travels as container env. Instead the value is written to a
  0600 file in a 0700 directory under `$XDG_RUNTIME_DIR` (tmpfs), bind-mounted
  read-only into the container (`Container` `:secrets_file`) and sourced by the
  command wrapper (`Container.secrets_wrapper/1`), so the process has the value
  in its environment while nothing podman persists does.

  Fail closed: with no runtime directory, or one that is not a tmpfs, there is
  nowhere safe to put a secret and `write/3` refuses. It never falls back to
  disk. The file is removed when the container exits and by `remove/2` from the
  reaper (a crashed agent leaves it until then, but only on tmpfs).

  The registry credential of a pull (SI4) is the same kind of file in the same
  directory, `pull-auth.json` (`write_authfile/3`), removed as soon as the pull ends.
  """

  @authfile "pull-auth.json"
  @config_home "config-home"

  @doc """
  The runtime directory secrets live under: `:runtime_dir`, else
  `$XDG_RUNTIME_DIR`.
  """
  @spec runtime_dir(keyword()) :: {:ok, Path.t()} | {:error, :no_runtime_dir}
  def runtime_dir(opts \\ []) do
    case Keyword.get(opts, :runtime_dir) || System.get_env("XDG_RUNTIME_DIR") do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:error, :no_runtime_dir}
    end
  end

  @doc "The 0700 directory holding run `run`'s secrets."
  @spec dir(Path.t(), String.t()) :: Path.t()
  def dir(runtime_dir, run), do: Path.join([runtime_dir, "arbiter-node", run])

  @doc "Where the secrets file of run `run` is."
  @spec file(Path.t(), String.t()) :: Path.t()
  def file(runtime_dir, run), do: Path.join(dir(runtime_dir, run), "secrets.env")

  @doc """
  Write `secrets` (`%{name => value}`) for `run`. Returns the file's path, or
  `{:ok, nil}` when there are none (nothing is created). Options: `:runtime_dir`,
  `:require_tmpfs` (default `true`; tests turn it off), `:mountinfo` (default
  `/proc/self/mountinfo`; a seam for tests).
  """
  @spec write(String.t(), %{optional(String.t()) => String.t()}, keyword()) ::
          {:ok, Path.t() | nil} | {:error, term()}
  def write(_run, secrets, _opts) when map_size(secrets) == 0, do: {:ok, nil}

  def write(run, secrets, opts) do
    with {:ok, root} <- runtime_dir(opts),
         :ok <- check_tmpfs(root, Keyword.get(opts, :require_tmpfs, true), opts) do
      write_private(dir(root, run), file(root, run), render(secrets))
    end
  end

  @doc """
  Where run `run`'s registry auth file is while its image is pulled (SI4,
  `docs/design/remote-workers.md` §21.4): in the run's secrets directory.
  """
  @spec authfile(Path.t(), String.t()) :: Path.t()
  def authfile(runtime_dir, run), do: Path.join(dir(runtime_dir, run), @authfile)

  @doc """
  Write `body`, a containers auth file holding the pull credential, for `run`'s
  pull, under `write/3`'s rules: a 0600 file in the run's 0700 directory on a
  tmpfs, refused (and nothing written) when there is none, the mode set before a
  byte is written. A file left by an earlier open of the run is removed first,
  never written through (a link there is unlinked, not followed). The caller
  removes it when the pull ends; `remove/2` (the run's cleanup, the reaper) takes it too.
  """
  @spec write_authfile(String.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def write_authfile(run, body, opts) when is_binary(body) do
    with {:ok, root} <- runtime_dir(opts),
         :ok <- check_tmpfs(root, Keyword.get(opts, :require_tmpfs, true), opts) do
      file = authfile(root, run)
      _ = File.rm(file)
      write_private(dir(root, run), file, body)
    end
  end

  # `:exclusive` is O_EXCL: it fails on anything already at `file`, a link included,
  # so nothing is ever written through one.
  defp write_private(dir, file, body) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, io} <- File.open(file, [:write, :exclusive]) do
      # The mode is set before a byte of the value is written.
      try do
        with :ok <- File.chmod(file, 0o600),
             :ok <- IO.binwrite(io, body) do
          {:ok, file}
        else
          {:error, reason} -> {:error, {:secrets_write_failed, reason}}
        end
      after
        File.close(io)
      end
    else
      {:error, reason} -> {:error, {:secrets_write_failed, reason}}
    end
  end

  @doc """
  Where run `run`'s config home is while it lives (SI8): a Codex run's `CODEX_HOME`
  (its login and generated config), a directory of its own on the tmpfs.
  """
  @spec config_home(Path.t(), String.t()) :: Path.t()
  def config_home(runtime_dir, run), do: Path.join(dir(runtime_dir, run), @config_home)

  @doc """
  Make run `run`'s config home on the tmpfs and write `files` (`%{relative path => bytes}`)
  into it (SI8, `docs/design/remote-workers.md` §21.3.3): every directory 0700, every file
  0600 with its mode set before a byte is written, created exclusively so nothing is
  written through a link. It holds a refresh token, so it is `write/3`'s tmpfs rule and
  stricter in one respect: even a run with no files gets its (empty) home only on a tmpfs.
  A path that is absolute, empty or climbs (`..`) is refused. Returns the home's path.
  Options as `write/3`.
  """
  @spec write_config_home(String.t(), %{optional(String.t()) => binary()}, keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def write_config_home(run, files, opts) when is_map(files) do
    with {:ok, root} <- runtime_dir(opts),
         :ok <- check_tmpfs(root, Keyword.get(opts, :require_tmpfs, true), opts),
         :ok <- check_relative(Map.keys(files)),
         home = config_home(root, run),
         :ok <- make_private_dir(dir(root, run)),
         :ok <- make_private_dir(home),
         :ok <- write_home_files(home, files) do
      {:ok, home}
    else
      {:error, {:secrets_write_failed, _}} = error ->
        # nothing half-written stays on the tmpfs
        with {:ok, root} <- runtime_dir(opts), do: remove_config_home(root, run)
        error

      {:error, _} = error ->
        error
    end
  end

  defp check_relative(paths) do
    bad =
      Enum.find(paths, fn path ->
        not is_binary(path) or path == "" or Path.type(path) != :relative or
          Enum.any?(Path.split(path), &(&1 in ["..", "."])) or String.contains?(path, <<0>>)
      end)

    if bad, do: {:error, {:secrets_write_failed, {:bad_path, bad}}}, else: :ok
  end

  defp make_private_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:secrets_write_failed, reason}}
    end
  end

  defp write_home_files(home, files) do
    Enum.reduce_while(files, :ok, fn {path, body}, :ok ->
      file = Path.join(home, path)

      with :ok <- make_private_tree(home, Path.dirname(path)),
           {:ok, io} <- File.open(file, [:write, :exclusive]) do
        try do
          with :ok <- File.chmod(file, 0o600),
               :ok <- IO.binwrite(io, body) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, {:secrets_write_failed, reason}}}
          end
        after
          File.close(io)
        end
      else
        {:error, {:secrets_write_failed, _}} = error -> {:halt, error}
        {:error, reason} -> {:halt, {:error, {:secrets_write_failed, reason}}}
      end
    end)
  end

  # `a/b` under `home`: each level made and set 0700 (mkdir_p's own mode follows the umask).
  defp make_private_tree(_home, "."), do: :ok

  defp make_private_tree(home, rel) do
    rel
    |> Path.split()
    |> Enum.reduce_while({home, :ok}, fn segment, {dir, :ok} ->
      next = Path.join(dir, segment)

      case make_private_dir(next) do
        :ok -> {:cont, {next, :ok}}
        error -> {:halt, {next, error}}
      end
    end)
    |> elem(1)
  end

  @doc """
  Remove run `run`'s config home recursively, **without following a link** (SI8): a link
  anywhere in the tree, the home itself included, is unlinked and its target left alone.
  Then the run's directory, if nothing else is in it. Idempotent.
  """
  @spec remove_config_home(Path.t() | nil, String.t()) :: :ok
  def remove_config_home(nil, _run), do: :ok

  def remove_config_home(runtime_dir, run) do
    _ = rm_tree(config_home(runtime_dir, run))
    _ = File.rmdir(dir(runtime_dir, run))
    :ok
  end

  # `File.lstat`, never `stat`: a directory is entered only when it is one itself.
  defp rm_tree(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        _ = File.chmod(path, 0o700)

        case File.ls(path) do
          {:ok, entries} -> Enum.each(entries, &rm_tree(Path.join(path, &1)))
          {:error, _} -> :ok
        end

        File.rmdir(path)

      {:ok, _other} ->
        File.rm(path)

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Remove run `run`'s secrets directory, its pull auth file and its config home included
  (idempotent). `keep_config_home: true` leaves the home: the run's own cleanup, which
  runs before the final upload that still needs it (`remove_config_home/2` follows).
  """
  @spec remove(Path.t() | nil, String.t(), keyword()) :: :ok
  def remove(runtime_dir, run, opts \\ [])
  def remove(nil, _run, _opts), do: :ok

  def remove(runtime_dir, run, opts) do
    dir = dir(runtime_dir, run)
    _ = File.rm(Path.join(dir, "secrets.env"))
    _ = File.rm(Path.join(dir, @authfile))

    if Keyword.get(opts, :keep_config_home, false),
      do: :ok,
      else: remove_config_home(runtime_dir, run)

    _ = File.rmdir(dir)
    :ok
  end

  @doc "Every run id with a secrets directory under `runtime_dir` (for the reaper)."
  @spec runs(Path.t()) :: [String.t()]
  def runs(runtime_dir) do
    case File.ls(Path.join(runtime_dir, "arbiter-node")) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  @doc "`export NAME='value'` lines; values are single-quoted, so nothing in one is interpreted."
  @spec render(%{optional(String.t()) => String.t()}) :: String.t()
  def render(secrets) do
    secrets
    |> Enum.sort()
    |> Enum.map_join(fn {name, value} -> "export #{name}=#{quote_value(value)}\n" end)
  end

  @doc false
  def quote_value(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  # -- tmpfs check ------------------------------------------------------------------

  defp check_tmpfs(_root, false, _opts), do: :ok

  defp check_tmpfs(root, true, opts) do
    case fstype(root, Keyword.get(opts, :mountinfo, "/proc/self/mountinfo")) do
      type when type in ["tmpfs", "ramfs"] -> :ok
      type -> {:error, {:secrets_not_on_tmpfs, root, type}}
    end
  end

  # The filesystem type of the longest mount point that prefixes `path`.
  defp fstype(path, mountinfo) do
    path = Path.expand(path)

    case File.read(mountinfo) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&mount_entry/1)
        |> Enum.filter(fn {mount, _} ->
          path == mount or String.starts_with?(path, mount <> "/") or mount == "/"
        end)
        |> Enum.max_by(fn {mount, _} -> byte_size(mount) end, fn -> {"/", nil} end)
        |> elem(1)

      {:error, _} ->
        nil
    end
  end

  # `36 35 98:0 /root /mnt rw,noatime - ext3 /dev/root rw` — the type is the
  # field after the `-` separator.
  defp mount_entry(line) do
    with [pre, post] <- String.split(line, " - ", parts: 2),
         [_, _, _, _, mount | _] <- String.split(pre, " "),
         [type | _] <- String.split(post, " ") do
      [{unescape(mount), type}]
    else
      _ -> []
    end
  end

  defp unescape(mount), do: String.replace(mount, "\\040", " ")
end

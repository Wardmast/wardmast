defmodule Wardmast.Worker.PathGuard do
  @moduledoc """
  Filesystem-path safety helpers for worktree provisioning.

  APFS (macOS default) and NTFS are case-insensitive, so two worktree leaves
  that differ only by case (`Fix-Foo` / `fix-foo`) name the same directory
  there while looking distinct to Linux. `case_collision/1` detects that
  everywhere so behaviour is identical on every host. `within?/2` is the
  containment check: it compares real paths (symlinks resolved, case-folded
  on a case-insensitive volume), not lexical `Path.expand/1` prefixes.
  """

  @doc """
  `:ok`, or `{:error, {:path_case_collision, path, existing}}` when a sibling of
  `path` that differs from its leaf only by case already exists.
  An exact-case existing leaf is not a collision.
  """
  @spec case_collision(Path.t()) :: :ok | {:error, {:path_case_collision, Path.t(), Path.t()}}
  def case_collision(path) when is_binary(path) do
    parent = Path.dirname(path)
    leaf = Path.basename(path)
    folded = String.downcase(leaf)

    case File.ls(parent) do
      {:ok, names} ->
        case Enum.find(names, &(&1 != leaf and String.downcase(&1) == folded)) do
          nil -> :ok
          other -> {:error, {:path_case_collision, path, Path.join(parent, other)}}
        end

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Resolve `path` to a real absolute path: every symlink in the existing prefix
  is followed, and a not-yet-existing tail is appended lexically.
  """
  @spec realpath(Path.t()) :: Path.t()
  def realpath(path) when is_binary(path), do: path |> Path.expand() |> resolve([], 0)

  defp resolve(path, tail, depth) when depth > 40, do: Path.join([path | tail])

  defp resolve(path, tail, depth) do
    case File.read_link(path) do
      {:ok, target} ->
        resolve(Path.expand(target, Path.dirname(path)), tail, depth + 1)

      {:error, :einval} ->
        resolve_parent(path, tail, depth)

      {:error, _} ->
        resolve_parent(path, tail, depth)
    end
  end

  defp resolve_parent("/", tail, _depth), do: Path.join(["/" | tail])

  defp resolve_parent(path, tail, depth) do
    parent = Path.dirname(path)

    if File.exists?(path) or parent == path do
      # Existing non-link leaf: resolve its parent chain.
      resolved_parent = resolve(parent, [], depth + 1)
      Path.join([resolved_parent, Path.basename(path) | tail])
    else
      resolve(parent, [Path.basename(path) | tail], depth + 1)
    end
  end

  @doc """
  True when the real path of `path` is `root` or inside it. Case-insensitive
  when `root` sits on a case-insensitive volume.
  """
  @spec within?(Path.t(), Path.t()) :: boolean()
  def within?(path, root) when is_binary(path) and is_binary(root) do
    real = realpath(path)
    real_root = realpath(root)

    {real, real_root} =
      if case_insensitive_dir?(real_root),
        do: {String.downcase(real), String.downcase(real_root)},
        else: {real, real_root}

    real == real_root or String.starts_with?(real, String.trim_trailing(real_root, "/") <> "/")
  end

  # A directory is on a case-insensitive volume when its upper/lower-cased
  # basename resolves to the same inode.
  defp case_insensitive_dir?(dir) do
    base = Path.basename(dir)
    flipped = if base == String.upcase(base), do: String.downcase(base), else: String.upcase(base)

    flipped != base and
      match?(
        {:ok, %File.Stat{inode: inode}} when inode != 0,
        File.stat(Path.join(Path.dirname(dir), flipped))
      ) and
      File.stat(Path.join(Path.dirname(dir), flipped)) == File.stat(dir)
  end
end

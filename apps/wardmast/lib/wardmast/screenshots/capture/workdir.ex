defmodule Wardmast.Screenshots.Capture.Workdir do
  @moduledoc """
  A capture's scratch trees (the before/after checkouts, each boot's scratch and deps copy),
  created and removed idempotently (bd-5eegxz).

  A tree copied from the read-only deps cache, or compiled by a dependency, can hold read-only
  directories, and `File.rm_rf/1` cannot remove those (`:eexist`, "file already exists"). Left
  behind, such a tree made the next boot at the same path fail. So:

    * `remove/1` makes the tree writable first, removes it, and **checks** that it is gone;
    * `attempt_dir/1` gives every capture run a work directory of its own (`work/<token>`), so a
      leftover from a killed or overlapping attempt at the same head is never shared with, or
      deleted from under, a live one;
    * `sweep/2` removes the leftovers of runs long dead.
  """

  alias Wardmast.Worker.ReleaseEnv

  @doc "Remove `path` (a file, a link or a tree, read-only or not); `:ok` once it is gone."
  @spec remove(String.t()) :: :ok | {:error, String.t()}
  def remove(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        _ = ReleaseEnv.cmd("chmod", ["-R", "u+rwX", "--", path], stderr_to_stdout: true)
        finish_remove(path, File.rm_rf(path))

      {:ok, _} ->
        finish_remove(path, File.rm_rf(path))

      {:error, reason} ->
        {:error, "could not inspect #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp finish_remove(path, {:ok, _}), do: still_there(path)

  defp finish_remove(path, {:error, reason, failed}) do
    case still_there(path) do
      :ok -> :ok
      _ -> {:error, "could not remove #{failed} (under #{path}): #{:file.format_error(reason)}"}
    end
  end

  defp still_there(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> {:error, "#{path} is still there after removing it"}
    end
  end

  @doc "The (not yet created) directory under `<out_dir>/work` that is one capture run's own."
  @spec attempt_dir(String.t()) :: String.t()
  def attempt_dir(out_dir),
    do: Path.join([out_dir, "work", Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)])

  @doc """
  Remove the run directories under `<out_dir>/work` whose last change is older than `max_age_s`
  (default one hour): the leftovers of runs that were killed before they could clean up. A run
  still going has touched its directory more recently than that.
  """
  @spec sweep(String.t(), non_neg_integer()) :: :ok
  def sweep(out_dir, max_age_s \\ 3600) do
    root = Path.join(out_dir, "work")
    cutoff = System.os_time(:second) - max_age_s

    case File.ls(root) do
      {:ok, entries} ->
        for entry <- entries,
            path = Path.join(root, entry),
            match?({:ok, %File.Stat{mtime: m}} when m < cutoff, File.stat(path, time: :posix)) do
          _ = remove(path)
        end

        :ok

      _ ->
        :ok
    end
  end
end

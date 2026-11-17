defmodule Wardmast.Worker.PortableCp do
  @moduledoc """
  `cp` argv that runs on both GNU coreutils and macOS's BSD `cp`.

  Seeding a worktree copies `deps/` and `_build/` with `cp -a --reflink=...`.
  `--reflink` is GNU-only: BSD `cp` (macOS) rejects it with `illegal option`, so
  on a Mac every seed failed (bd-datu4q, epic bd-aafll7). Callers keep writing
  the GNU argv and pass it through `args/1`, which is the identity on every
  other host.

  On darwin:

    * `--reflink=always` becomes `-c` (`clonefile(2)`, APFS's copy-on-write
      clone). On a volume that cannot clone, `cp` exits non-zero, exactly like
      GNU's `--reflink=always`, so the caller's fallback to a plain copy still
      fires.
    * `--reflink=auto` and `--reflink=never` are dropped: a plain `cp -a` is a
      correct full copy.
  """

  @doc "Translate GNU-only `cp` flags for the host (`:os.type/0`)."
  @spec args([String.t()]) :: [String.t()]
  def args(argv), do: args(argv, :os.type())

  @doc "As `args/1`, for an explicit `os_type` (testable without a Mac)."
  @spec args([String.t()], {atom(), atom()}) :: [String.t()]
  def args(argv, {:unix, :darwin}), do: Enum.flat_map(argv, &darwin_flag/1)
  def args(argv, _os_type), do: argv

  defp darwin_flag("--reflink=always"), do: ["-c"]
  defp darwin_flag("--reflink=" <> _auto_or_never), do: []
  defp darwin_flag(arg), do: [arg]
end

defmodule Wardmast.Worker.JailReadonlyPathsTest do
  # async: false — every `wrap/2` writes the ssh mirror under the global
  # `:worker_jail_ssh_shadow_root`, which the setup points at the test's own dir.
  use ExUnit.Case, async: false

  alias Wardmast.Test.JailProbe
  alias Wardmast.Worker.Jail

  @moduletag :capture_log
  @moduletag :bwrap

  @bwrap_skip JailProbe.skip_reason(Jail.probe())
  if @bwrap_skip, do: @moduletag(skip: @bwrap_skip)

  # `wrap/2`'s `:readonly_paths` under a real bwrap (bd-bzhpgi), in the shape of
  # qwen's system settings, attacked the ways a worker would go about rewriting its
  # own policy. Both layouts must hold: a read-only dir nested in the writable home
  # (what #1532 took the 26.04 failure for) and one beside it under a writable
  # parent (where qwen keeps it, a sibling of its home in the hidden home root).
  @attack ~S"""
  f="$RO/settings.json"
  grep -q POLICY "$f" && echo PRESENT
  err=$( { echo '{}' > "$f"; } 2>&1 ); echo "write: $err"
  echo "$err" | grep -qi 'read-only file system' && echo WRITE_EROFS
  err=$(rm -f "$f" 2>&1); echo "rm: $err"
  echo "$err" | grep -qi 'read-only file system' && echo RM_EROFS
  err=$( { echo '{}' > "$f.new"; } 2>&1 ); echo "sibling: $err"
  echo "$err" | grep -qi 'read-only file system' && echo SIBLING_EROFS
  echo '{}' > "$HOME/evil.json"
  err=$(mv -f "$HOME/evil.json" "$f" 2>&1) || echo RENAME_REFUSED
  echo "rename: $err"
  err=$(mv "$RO" "$RO.aside" 2>&1) || echo DIR_RENAME_REFUSED
  echo "dir rename: $err"
  grep -q POLICY "$f" && echo INTACT
  grep -F " $RO " /proc/self/mountinfo | sed 's/^/MOUNTINFO: /'
  exit 0
  """

  @markers ~w(PRESENT WRITE_EROFS RM_EROFS SIBLING_EROFS RENAME_REFUSED DIR_RENAME_REFUSED INTACT)

  setup do
    uniq = "#{System.pid()}-#{System.unique_integer([:positive])}"
    # Not under /tmp: the jail mounts a private tmpfs there.
    base = Path.join(Wardmast.Config.Paths.scratch_root(), "jail-ro-test-#{uniq}")
    wt = Path.join(base, "wt")
    File.mkdir_p!(wt)

    prev = Application.get_env(:wardmast, :worker_jail_ssh_shadow_root)
    Application.put_env(:wardmast, :worker_jail_ssh_shadow_root, Path.join(base, "shadow"))

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:wardmast, :worker_jail_ssh_shadow_root),
        else: Application.put_env(:wardmast, :worker_jail_ssh_shadow_root, prev)

      File.rm_rf!(base)
    end)

    {:ok, base: base, wt: wt}
  end

  defp policy_dir!(dir) do
    File.mkdir_p!(dir)
    file = Path.join(dir, "settings.json")
    File.write!(file, ~s({"POLICY": "deny"}\n))
    File.chmod!(file, 0o444)
    file
  end

  defp run_attack(opts, ro) do
    {:ok, [bwrap | args]} = Jail.wrap(["sh", "-c", @attack], opts)

    System.cmd(bwrap, args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}, {"RO", ro}])
  end

  defp assert_held(out, ro, file) do
    for marker <- @markers, do: assert(out =~ marker, "missing #{marker} in:\n#{out}")
    # mountinfo: field 5 is the mount point, field 6 its per-mount options
    assert out =~ ~r/^MOUNTINFO: \S+ \S+ \S+ \S+ #{Regex.escape(ro)} ro[ ,]/m, out
    assert File.read!(file) == ~s({"POLICY": "deny"}\n)
    refute File.exists?(file <> ".new")
    refute File.exists?(ro <> ".aside")
  end

  test "a read-only dir nested in the writable home holds against write, delete, replace and rename",
       %{base: base, wt: wt} do
    home = Path.join(base, "home")
    ro = Path.join(home, ".policy")
    file = policy_dir!(ro)

    {out, status} = run_attack([worktree: wt, home: home, readonly_paths: [ro]], ro)

    assert status == 0, out
    assert_held(out, ro, file)
  end

  test "a read-only dir beside the home, under a writable parent, holds the same way",
       %{base: base, wt: wt} do
    homes = Path.join(base, "homes")
    home = Path.join(homes, "w")
    ro = Path.join(homes, "w.policy")
    File.mkdir_p!(home)
    file = policy_dir!(ro)

    {out, status} =
      run_attack([worktree: wt, home: home, writable_paths: [homes], readonly_paths: [ro]], ro)

    assert status == 0, out
    assert_held(out, ro, file)
  end

  test "a read-only path missing at spawn refuses the jail instead of running without it",
       %{base: base, wt: wt} do
    missing = Path.join(base, "no-such-policy")

    {:ok, [bwrap | args]} =
      Jail.wrap(["sh", "-c", "echo JAIL_RAN"], worktree: wt, readonly_paths: [missing])

    {out, status} = System.cmd(bwrap, args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])

    assert status != 0, out
    refute out =~ "JAIL_RAN"
    assert out =~ missing
  end
end

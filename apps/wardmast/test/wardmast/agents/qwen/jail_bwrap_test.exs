defmodule Wardmast.Agents.Qwen.JailBwrapTest do
  # async: false — PATH and the jail / home Application env are global.
  use Wardmast.DataCase, async: false

  alias Wardmast.Agents.Qwen
  alias Wardmast.Agents.Qwen.ConfigDir
  alias Wardmast.Agents.SecurityPolicy
  alias Wardmast.Test.JailProbe
  alias Wardmast.Worker.Jail

  @moduletag :capture_log
  @moduletag :bwrap

  @bwrap_skip JailProbe.skip_reason(Jail.probe())
  if @bwrap_skip, do: @moduletag(skip: @bwrap_skip)

  # The real `Qwen.default_argv/2` under a real bwrap, with a stub `qwen` that
  # tries the writes the policy forbids. The filesystem jail only: the network
  # namespace and its bridges are exercised by `jail_network_test.exs`.
  #
  # The stub attacks the settings at `$QWEN_CODE_SYSTEM_SETTINGS_PATH`, the path
  # the jail hands qwen, and first checks the file is there. It used to attack a
  # path this setup worked out before it set `:worker_qwen_home_root`: a directory
  # under the default root that nothing mounted, so the write failed with ENOENT
  # (not EROFS) on every host where the jail really ran, and ubuntu-26.04 was the
  # first CI image where it did (#1541, bd-bzhpgi).
  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "qwen-jail-bwrap-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    wt = Path.join(base, "wt")
    # The stub lives in the (bound) worktree: the jail's `--tmpfs /tmp` hides
    # anything else under a /tmp TMPDIR, as it does in CI.
    bin = Path.join(wt, ".stub-bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "qwen"), """
    #!/bin/sh
    sys="$QWEN_CODE_SYSTEM_SETTINGS_PATH"
    dir="${sys%/*}"
    echo "SETTINGS_PATH=$sys"
    # the target is there and holds the policy, so a refusal below means something
    grep -q '"deny"' "$sys" && echo SETTINGS_PRESENT
    { echo changed > "#{wt}/review-write.txt"; } 2>&1 | grep -qi 'read-only file system' && echo WORKTREE_EROFS
    echo ok > "$HOME/home-write.txt" && echo HOME_WRITE_OK
    # each attack prints its raw error, then a marker when it was refused
    err=$( { echo '{}' > "$sys"; } 2>&1 ); echo "write: $err"
    echo "$err" | grep -qi 'read-only file system' && echo SETTINGS_EROFS
    err=$(rm -f "$sys" 2>&1); echo "rm: $err"
    echo "$err" | grep -qi 'read-only file system' && echo SETTINGS_RM_EROFS
    # replace it the way ConfigDir writes it: a sibling, renamed over the target
    err=$( { echo '{}' > "$sys.new"; } 2>&1 ); echo "sibling: $err"
    echo "$err" | grep -qi 'read-only file system' && echo SETTINGS_SIBLING_EROFS
    # rename a file of its own, from the writable HOME, over it
    echo '{}' > "$HOME/evil.json"
    err=$(mv -f "$HOME/evil.json" "$sys" 2>&1) || echo SETTINGS_RENAME_REFUSED
    echo "rename: $err"
    # move the directory aside, to put a writable one in its place
    err=$(mv "$dir" "$dir.aside" 2>&1) || echo SETTINGS_DIR_RENAME_REFUSED
    echo "dir rename: $err"
    # whatever happened above, qwen still reads the policy
    grep -q '"deny"' "$sys" && echo SETTINGS_INTACT
    # how the settings dir is mounted in the jail
    grep -F " $dir " /proc/self/mountinfo | sed 's/^/MOUNTINFO: /'
    exit 0
    """)

    File.chmod!(Path.join(bin, "qwen"), 0o755)

    keys = ~w(worker_qwen_home_root worker_jail_available worker_jail_bwrap worker_jail_network
              worker_jail_ssh_shadow_root)a

    prev = Map.new(keys, &{&1, Application.get_env(:wardmast, &1)})
    old_path = System.get_env("PATH")

    Application.put_env(:wardmast, :worker_qwen_home_root, Path.join(base, "homes"))
    Application.put_env(:wardmast, :worker_jail_ssh_shadow_root, Path.join(base, "shadow"))
    Application.put_env(:wardmast, :worker_jail_network, false)
    Application.delete_env(:wardmast, :worker_jail_available)
    Application.delete_env(:wardmast, :worker_jail_bwrap)
    System.put_env("PATH", bin <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:wardmast, k)
        {k, v} -> Application.put_env(:wardmast, k, v)
      end)

      File.rm_rf!(base)
    end)

    {:ok, wt: wt}
  end

  defp run(argv, label) do
    [cmd | args] = argv
    {out, status} = System.cmd(cmd, args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
    JailProbe.evidence("qwen #{label}: system settings", out)
    {out, status}
  end

  # What `ConfigDir.ensure/1` wrote for this spawn, read on the host before the run.
  defp settings_before(wt) do
    sys = ConfigDir.system_settings_path(worktree: wt)
    body = File.read!(sys)
    assert body =~ ~s("deny"), body
    body
  end

  # The settings held: the stub attacked the file `ConfigDir` wrote (it was there
  # and held the policy), the write, the delete and the replace by sibling were
  # refused with EROFS, both renames were refused, the policy was still there
  # afterwards, the jail mounted the directory read-only, and the host copy is
  # byte-for-byte what it was.
  defp assert_settings_held(out, wt, before) do
    sys = ConfigDir.system_settings_path(worktree: wt)
    dir = Path.dirname(sys)

    assert out =~ "SETTINGS_PATH=#{sys}\n", out

    for marker <-
          ~w(SETTINGS_PRESENT SETTINGS_EROFS SETTINGS_RM_EROFS SETTINGS_SIBLING_EROFS
             SETTINGS_RENAME_REFUSED SETTINGS_DIR_RENAME_REFUSED SETTINGS_INTACT) do
      assert out =~ marker, "missing #{marker} in:\n#{out}"
    end

    # mountinfo: field 5 is the mount point, field 6 its per-mount options
    assert out =~ ~r/^MOUNTINFO: \S+ \S+ \S+ \S+ #{Regex.escape(dir)} ro[ ,]/m, out

    assert File.read!(sys) == before
    refute File.exists?(sys <> ".new")
    refute File.exists?(dir <> ".aside")
  end

  test "a reviewer's qwen cannot write the worktree, keeps its home writable and cannot touch its own settings",
       %{wt: wt} do
    policy =
      SecurityPolicy.merge(SecurityPolicy.default(), %{
        "permissions" => %{"deny" => ["Edit", "Write", "NotebookEdit"]}
      })

    assert {:ok, argv} =
             Qwen.default_argv("review", worktree: wt, security: policy, owner: self())

    before = settings_before(wt)
    {out, status} = run(argv, "reviewer")

    assert status == 0, out
    assert out =~ "WORKTREE_EROFS", out
    assert out =~ "HOME_WRITE_OK", out
    refute File.exists?(Path.join(wt, "review-write.txt"))
    assert_settings_held(out, wt, before)
  end

  test "an implementer's qwen can write the worktree (the control for the test above)", %{wt: wt} do
    assert {:ok, argv} =
             Qwen.default_argv("implement",
               worktree: wt,
               security: SecurityPolicy.default(),
               owner: self()
             )

    before = settings_before(wt)
    {out, status} = run(argv, "implementer")

    assert status == 0, out
    refute out =~ "WORKTREE_EROFS"
    assert File.read!(Path.join(wt, "review-write.txt")) == "changed\n"
    # the settings stay read-only for an implementer too
    assert_settings_held(out, wt, before)
  end
end

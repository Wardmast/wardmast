defmodule Wardmast.Agents.Gemini.JailBwrapTest do
  # async: false — PATH and the jail / home Application env are global.
  use Wardmast.DataCase, async: false

  alias Wardmast.Agents.Gemini
  alias Wardmast.Agents.Gemini.ConfigDir
  alias Wardmast.Agents.SecurityPolicy
  alias Wardmast.Test.JailProbe
  alias Wardmast.Worker.Jail

  @moduletag :capture_log
  @moduletag :bwrap

  @bwrap_skip JailProbe.skip_reason(Jail.probe())
  if @bwrap_skip, do: @moduletag(skip: @bwrap_skip)

  # bd-8oqkj2: the real `Gemini.default_argv/2` for agy under a real bwrap, with a
  # stub `agy` that tries to rewrite its own posture, `$HOME/.gemini/antigravity-cli/
  # settings.json` (the `toolPermission` and `permissions.deny` file). It is a file in
  # the writable HOME, bound read-only on its own; the directory stays writable
  # because agy writes other files beside it (`cache/onboarding.json`). The
  # filesystem jail only: the network namespace is `jail_network_test.exs`'s.
  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "agy-jail-bwrap-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    wt = Path.join(base, "wt")
    # The stub lives in the (bound) worktree: the jail's `--tmpfs /tmp` hides
    # anything else under a /tmp TMPDIR, as it does in CI.
    bin = Path.join(wt, ".stub-bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "agy"), """
    #!/bin/sh
    sys="$HOME/.gemini/antigravity-cli/settings.json"
    dir="${sys%/*}"
    echo "SETTINGS_PATH=$sys"
    # the target is there and holds the policy, so a refusal below means something
    grep -q '"deny"' "$sys" && echo SETTINGS_PRESENT
    # what agy's own startup does around the file: read it, and write beside it
    cat "$sys" > /dev/null && echo SETTINGS_READ_OK
    mkdir -p "$dir/cache" "$HOME/.gemini/antigravity" \\
      && echo '{"onboardingComplete":true}' > "$dir/cache/onboarding.json" \\
      && echo '{}' > "$dir/state.json" \\
      && echo '{}' > "$HOME/.gemini/antigravity/conversation.pb" \\
      && echo STARTUP_WRITES_OK
    # each attack prints its raw error, then a marker when it was refused
    err=$( { echo '{}' > "$sys"; } 2>&1 ); echo "write: $err"
    echo "$err" | grep -qi 'read-only file system' && echo SETTINGS_EROFS
    err=$( { echo '{}' >> "$sys"; } 2>&1 ); echo "append: $err"
    echo "$err" | grep -qi 'read-only file system' && echo SETTINGS_APPEND_EROFS
    err=$( { : > "$sys"; } 2>&1 ); echo "truncate: $err"
    echo "$err" | grep -qi 'read-only file system' && echo SETTINGS_TRUNCATE_EROFS
    err=$(rm -f "$sys" 2>&1) && echo SETTINGS_RM_SUCCEEDED
    echo "rm: $err"
    echo "$err" | grep -qiE 'read-only file system|busy' && echo SETTINGS_RM_REFUSED
    # replace it the way ConfigDir writes it: a sibling, renamed over the target
    echo '{}' > "$sys.new" && echo SIBLING_WRITTEN
    err=$(mv -f "$sys.new" "$sys" 2>&1) || echo SETTINGS_SIBLING_RENAME_REFUSED
    echo "sibling rename: $err"
    # rename a file of its own, from the writable HOME, over it
    echo '{}' > "$HOME/evil.json"
    err=$(mv -f "$HOME/evil.json" "$sys" 2>&1) || echo SETTINGS_RENAME_REFUSED
    echo "rename: $err"
    # whatever happened above, agy still reads the policy
    grep -q '"deny"' "$sys" && echo SETTINGS_INTACT
    # recorded, not asserted: moving the directory aside is the residual
    # (see ConfigDir's moduledoc); only a directory-level bind would stop it
    err=$(mv "$dir" "$dir.aside" 2>&1) && echo "DIR_RENAME: succeeded" || echo "DIR_RENAME: refused: $err"
    # how the settings file is mounted in the jail
    grep -F " $sys " /proc/self/mountinfo | sed 's/^/MOUNTINFO: /'
    exit 0
    """)

    File.chmod!(Path.join(bin, "agy"), 0o755)

    keys =
      ~w(worker_agy_home_root worker_isolate_config worker_jail_available worker_jail_bwrap
         worker_jail_network worker_jail_ssh_shadow_root worker_gemini_keyring_available)a

    prev = Map.new(keys, &{&1, Application.fetch_env(:wardmast, &1)})
    old_path = System.get_env("PATH")

    Application.put_env(:wardmast, :worker_agy_home_root, Path.join(base, "homes"))
    Application.put_env(:wardmast, :worker_isolate_config, true)
    Application.put_env(:wardmast, :worker_jail_ssh_shadow_root, Path.join(base, "shadow"))
    Application.put_env(:wardmast, :worker_jail_network, false)
    # a jailed agy needs a keyring; the jail runs without a bus where there is none
    Application.put_env(:wardmast, :worker_gemini_keyring_available, true)
    Application.delete_env(:wardmast, :worker_jail_available)
    Application.delete_env(:wardmast, :worker_jail_bwrap)
    System.put_env("PATH", bin <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)

      Enum.each(prev, fn
        {k, {:ok, v}} -> Application.put_env(:wardmast, k, v)
        {k, :error} -> Application.delete_env(:wardmast, k)
      end)

      File.rm_rf!(base)
    end)

    {:ok, wt: wt}
  end

  defp strict_policy,
    do:
      SecurityPolicy.merge(SecurityPolicy.default(), %{
        "permissions" => %{"mode" => "strict"}
      })

  defp run(argv, label) do
    [cmd | args] = argv
    {out, status} = System.cmd(cmd, args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
    JailProbe.evidence("agy #{label}: settings.json", out)
    {out, status}
  end

  test "agy starts, writes beside settings.json, and cannot rewrite, delete or replace its own posture",
       %{wt: wt} do
    assert {:ok, argv} =
             Gemini.default_argv("the prompt",
               worktree_path: wt,
               security: strict_policy(),
               owner: self()
             )

    sys = ConfigDir.settings_path(worktree_path: wt)
    dir = Path.dirname(sys)
    before = File.read!(sys)
    assert before =~ ~s("deny"), before

    {out, status} = run(argv, "strict")

    assert status == 0, out
    assert out =~ "SETTINGS_PATH=#{sys}\n", out

    # agy's startup path: it reads the file and its other files stay writable
    for marker <- ~w(SETTINGS_PRESENT SETTINGS_READ_OK STARTUP_WRITES_OK) do
      assert out =~ marker, "missing #{marker} in:\n#{out}"
    end

    # write, append and truncate: EROFS; unlink: EROFS or EBUSY; a sibling or a
    # file of its own renamed over it: refused; the policy is still there
    for marker <-
          ~w(SETTINGS_EROFS SETTINGS_APPEND_EROFS SETTINGS_TRUNCATE_EROFS SETTINGS_RM_REFUSED
             SIBLING_WRITTEN SETTINGS_SIBLING_RENAME_REFUSED SETTINGS_RENAME_REFUSED
             SETTINGS_INTACT) do
      assert out =~ marker, "missing #{marker} in:\n#{out}"
    end

    refute out =~ "SETTINGS_RM_SUCCEEDED", out

    # mountinfo: field 5 is the mount point, field 6 its per-mount options; only
    # the file is a read-only mount, the directory beside it is not
    assert out =~ ~r/^MOUNTINFO: \S+ \S+ \S+ \S+ #{Regex.escape(sys)} ro[ ,]/m, out
    refute out =~ ~r/^MOUNTINFO: \S+ \S+ \S+ \S+ #{Regex.escape(dir)} ro[ ,]/m, out

    # the host's copy is byte-for-byte what was generated, and the files agy wrote
    # beside it went through to the writable HOME
    assert File.read!(sys) == before
    assert File.read!(Path.join(dir, "cache/onboarding.json")) =~ "onboardingComplete"
    assert File.regular?(Path.join(dir, "state.json"))
  end
end

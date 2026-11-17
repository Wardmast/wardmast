defmodule WardmastCli.Cmd.SelfUpdateTest do
  # async: false — mutates global env (ARB_INSTALL_BIN, ARB_RELEASE_REPO, GITHUB_TOKEN).
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Cmd.SelfUpdate

  @repo "acme/arbiter"
  @vsn "v0.2.0"

  setup do
    tmp = Path.join(System.tmp_dir!(), "ward-self-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    install_path = Path.join(tmp, "ward")

    System.put_env("WARDMAST_INSTALL_BIN", install_path)
    System.delete_env("ARB_INSTALL_BIN")
    System.put_env("ARB_RELEASE_REPO", @repo)
    System.delete_env("GITHUB_TOKEN")
    System.delete_env("ARB_GITHUB_API")

    on_exit(fn ->
      System.delete_env("WARDMAST_INSTALL_BIN")
      System.delete_env("ARB_INSTALL_BIN")
      System.delete_env("ARB_RELEASE_REPO")
      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, install_path: install_path}
  end

  # ---- fixtures -----------------------------------------------------------

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp release_json(tag) do
    %{
      "tag_name" => tag,
      "assets" => [
        %{"name" => "ward", "browser_download_url" => "https://dl.test/dl/#{tag}/ward"},
        %{
          "name" => "ward.sha256",
          "browser_download_url" => "https://dl.test/dl/#{tag}/ward.sha256"
        }
      ]
    }
  end

  defp stub_release(tag, ward_bytes, sha_text, opts \\ []) do
    latest? = Keyword.get(opts, :latest, true)

    api_path =
      if latest?,
        do: "/repos/#{@repo}/releases/latest",
        else: "/repos/#{@repo}/releases/tags/#{tag}"

    stub_routes([
      {{"get", api_path}, {release_json(tag), 200}},
      {{"get", "/dl/#{tag}/ward"},
       fn conn ->
         conn
         |> Plug.Conn.put_resp_content_type("application/octet-stream")
         |> Plug.Conn.send_resp(200, ward_bytes)
       end},
      {{"get", "/dl/#{tag}/ward.sha256"},
       fn conn ->
         conn
         |> Plug.Conn.put_resp_content_type("text/plain")
         |> Plug.Conn.send_resp(200, sha_text)
       end}
    ])
  end

  # ---- happy path ---------------------------------------------------------

  describe "self-update (happy path)" do
    test "downloads, verifies checksum, installs `ward`, `wm` symlink, and `arb` shim", %{
      tmp: tmp,
      install_path: install_path
    } do
      ward_bytes = "#!/usr/bin/env escript\n% fake ward #{@vsn}\n"
      sha = "#{sha256_hex(ward_bytes)}  ward\n"
      stub_release(@vsn, ward_bytes, sha)

      # Install a fake old binary first so we can confirm backup.
      File.write!(install_path, "old ward binary")

      {out, _err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 0
      assert out =~ "Updated ward to #{@vsn}"
      assert out =~ install_path

      # The new binary was installed.
      assert File.read!(install_path) == ward_bytes

      # The old binary was backed up.
      assert File.read!(install_path <> ".bak") == "old ward binary"

      # The new binary is executable.
      %File.Stat{mode: mode} = File.stat!(install_path)
      assert Bitwise.band(mode, 0o111) != 0

      # `wm` is installed alongside `ward` as a symlink to `ward`.
      wm_path = Path.join(tmp, "wm")
      assert {:ok, "ward"} = File.read_link(wm_path)

      # `arb` is installed alongside `ward` as an executable shim.
      arb_path = Path.join(tmp, "arb")
      assert File.regular?(arb_path)
      %File.Stat{mode: arb_mode} = File.stat!(arb_path)
      assert Bitwise.band(arb_mode, 0o111) != 0
    end

    test "`arb` shim prints a one-line deprecation notice to stderr and forwards argv/exit code to `ward`",
         %{tmp: tmp, install_path: install_path} do
      # Install a fake `ward` script that echoes its argv to stdout and exits with $FAKE_EXIT.
      fake_ward = """
      #!/bin/sh
      printf 'args:%s\\n' "$*"
      exit "${FAKE_EXIT:-0}"
      """

      sha = "#{sha256_hex(fake_ward)}  ward\n"
      stub_release(@vsn, fake_ward, sha)

      {_out, _err, 0} = capture(fn -> SelfUpdate.run([]) end)
      assert File.exists?(install_path)

      arb_path = Path.join(tmp, "arb")
      wm_path = Path.join(tmp, "wm")

      # Split stdout and stderr by redirecting stderr to a temp file.
      err_file = Path.join(tmp, "stderr.txt")

      {stdout, 0} =
        System.cmd(
          "sh",
          ["-c", ~s("#{arb_path}" ticket show "bd-123" --json 2>"#{err_file}")],
          env: [{"FAKE_EXIT", "0"}]
        )

      stderr = File.read!(err_file)
      assert stdout == "args:ticket show bd-123 --json\n"
      assert stderr =~ "deprecated"
      assert stderr =~ "ward"
      assert length(String.split(String.trim(stderr), "\n")) == 1

      # Non-zero exit code is forwarded verbatim.
      {stdout_42, 42} =
        System.cmd(
          "sh",
          ["-c", ~s("#{arb_path}" --bogus 2>"#{err_file}")],
          env: [{"FAKE_EXIT", "42"}]
        )

      assert stdout_42 == "args:--bogus\n"

      # `wm` symlink forwards argv/exit code with NO deprecation notice on stderr.
      {wm_stdout, 0} =
        System.cmd(
          "sh",
          ["-c", ~s("#{wm_path}" ticket list 2>"#{err_file}")],
          env: [{"FAKE_EXIT", "0"}]
        )

      assert wm_stdout == "args:ticket list\n"
      assert File.read!(err_file) == ""
    end

    test "--json emits a single object describing the update", %{install_path: install_path} do
      arb_bytes = "#!/usr/bin/env escript\n% fake arb #{@vsn}\n"
      sha = "#{sha256_hex(arb_bytes)}  arb\n"
      stub_release(@vsn, arb_bytes, sha)
      File.write!(install_path, "old")

      {out, _err, code} = capture(fn -> SelfUpdate.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["version"] == @vsn
      assert payload["updated"] == true
      assert payload["already_current"] == false
      assert payload["ok"] == true
    end

    test "--version targets a specific tag via the tags endpoint", %{install_path: install_path} do
      tag = "v0.1.5"
      ward_bytes = "#!/usr/bin/env escript\n% fake ward #{tag}\n"
      sha = "#{sha256_hex(ward_bytes)}  ward\n"
      stub_release(tag, ward_bytes, sha, latest: false)
      File.write!(install_path, "old")

      {out, _err, code} = capture(fn -> SelfUpdate.run(["--version", tag]) end)

      assert code == 0
      assert out =~ "Updated ward to #{tag}"
    end

    test "creates the install directory if absent" do
      new_dir = Path.join(System.tmp_dir!(), "ward-newdir-#{System.unique_integer([:positive])}")
      new_path = Path.join(new_dir, "ward")
      System.put_env("WARDMAST_INSTALL_BIN", new_path)

      on_exit(fn ->
        System.delete_env("WARDMAST_INSTALL_BIN")
        File.rm_rf(new_dir)
      end)

      ward_bytes = "fake ward"
      sha = "#{sha256_hex(ward_bytes)}  ward\n"
      stub_release(@vsn, ward_bytes, sha)

      {_out, _err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 0
      assert File.exists?(new_path)
      assert {:ok, "ward"} = File.read_link(Path.join(new_dir, "wm"))
      assert File.exists?(Path.join(new_dir, "arb"))
    end
  end

  # ---- already-current no-op ----------------------------------------------

  describe "already-current no-op" do
    test "skips download when already on the target version" do
      # The running CLI's version is WardmastCli.Version.app_version().
      # We need to make the release tag match that version.
      current = WardmastCli.Version.app_version()
      tag = "v#{current}"

      ward_bytes = "fake ward"
      sha = "#{sha256_hex(ward_bytes)}  ward\n"
      stub_release(tag, ward_bytes, sha)

      {out, _err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 0
      assert out =~ "Already on #{tag}"
    end

    test "--force reinstalls even when already on the target version", %{
      install_path: install_path
    } do
      current = WardmastCli.Version.app_version()
      tag = "v#{current}"
      ward_bytes = "new ward bytes"
      sha = "#{sha256_hex(ward_bytes)}  ward\n"
      stub_release(tag, ward_bytes, sha)
      File.write!(install_path, "old bytes")

      {out, _err, code} = capture(fn -> SelfUpdate.run(["--force"]) end)

      assert code == 0
      assert out =~ "Updated ward to #{tag}"
      assert File.read!(install_path) == ward_bytes
    end
  end

  # ---- checksum verification ----------------------------------------------

  describe "checksum verification" do
    test "aborts on sha256 mismatch before writing anything", %{install_path: install_path} do
      ward_bytes = "fake ward"
      bad_sha = "#{String.duplicate("0", 64)}  ward\n"
      stub_release(@vsn, ward_bytes, bad_sha)
      File.write!(install_path, "original")

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "checksum mismatch"

      # Original binary is untouched.
      assert File.read!(install_path) == "original"
    end
  end

  # ---- configuration errors -----------------------------------------------

  describe "configuration errors" do
    test "no resolvable release repo aborts with a hint" do
      System.delete_env("ARB_RELEASE_REPO")
      Process.put(:bd2_build_release_repo, false)

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "ARB_RELEASE_REPO"
    end

    test "no matching release (404) aborts" do
      stub_routes([
        {{"get", "/repos/#{@repo}/releases/latest"}, {%{"message" => "Not Found"}, 404}}
      ])

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "no latest release found"
    end

    test "release with no `ward` asset aborts" do
      no_ward_release = %{
        "tag_name" => @vsn,
        "assets" => [
          %{"name" => "arbiter-#{@vsn}-linux.tar.gz", "browser_download_url" => "https://x/x.tgz"}
        ]
      }

      stub_routes([
        {{"get", "/repos/#{@repo}/releases/latest"}, {no_ward_release, 200}}
      ])

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "no asset named `ward`"
    end

    test "release with no `ward.sha256` asset aborts" do
      no_sha_release = %{
        "tag_name" => @vsn,
        "assets" => [
          %{"name" => "ward", "browser_download_url" => "https://x/ward"}
        ]
      }

      stub_routes([
        {{"get", "/repos/#{@repo}/releases/latest"}, {no_sha_release, 200}}
      ])

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "ward.sha256"
    end
  end

  describe "install_links when arb is the running escript" do
    test "defers the shim until flush_pending_shim/0", %{tmp: tmp, install_path: ward} do
      arb = Path.join(tmp, "arb")
      File.write!(arb, "ORIGINAL ESCRIPT")
      Process.put(:arb_running_script_override, arb)
      on_exit(fn -> Process.delete(:arb_running_script_override) end)

      assert :ok = SelfUpdate.install_links(ward)
      # The running file is untouched until the caller is done.
      assert File.read!(arb) == "ORIGINAL ESCRIPT"
      assert File.exists?(arb <> ".new")

      assert :ok = SelfUpdate.flush_pending_shim()
      assert File.read!(arb) =~ "#!/bin/sh"
      refute File.exists?(arb <> ".new")
      assert :ok = SelfUpdate.flush_pending_shim()
    end

    test "writes the shim immediately when arb is not the running script", %{
      tmp: tmp,
      install_path: ward
    } do
      Process.put(:arb_running_script_override, Path.join(tmp, "other"))
      on_exit(fn -> Process.delete(:arb_running_script_override) end)

      assert :ok = SelfUpdate.install_links(ward)
      assert File.read!(Path.join(tmp, "arb")) =~ "#!/bin/sh"
    end
  end
end

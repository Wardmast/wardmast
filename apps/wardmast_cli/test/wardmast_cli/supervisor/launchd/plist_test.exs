defmodule WardmastCli.Supervisor.Launchd.PlistTest do
  use ExUnit.Case, async: true

  alias WardmastCli.Supervisor.Launchd.Plist

  @opts [
    root: "/Users/me/dev/wardmast",
    arbiter_home: "/Users/me/.wardmast",
    env: [{"WARDMAST_HOST", "http://localhost:4848"}]
  ]

  describe "label/0 and file_name/0" do
    test "the label is reverse-DNS and the file is <label>.plist" do
      assert Plist.label() == "com.wardmast.server"
      assert Plist.file_name() == "com.wardmast.server.plist"
    end
  end

  describe "plist/1" do
    test "is an XML property list with the label" do
      xml = Plist.plist(@opts)

      assert xml =~ ~s(<?xml version="1.0" encoding="UTF-8"?>)
      assert xml =~ "<!DOCTYPE plist PUBLIC"
      assert xml =~ "<key>Label</key>\n  <string>com.wardmast.server</string>"
    end

    test "runs the env wrapper under /bin/sh from the checkout root" do
      xml = Plist.plist(@opts)

      assert xml =~
               "<key>ProgramArguments</key>\n  <array>\n    <string>/bin/sh</string>\n" <>
                 "    <string>/Users/me/.wardmast/launchd-run.sh</string>\n  </array>"

      assert xml =~ "<key>WorkingDirectory</key>\n  <string>/Users/me/dev/wardmast</string>"
    end

    test "starts at load and restarts only after a failed exit (Restart=on-failure)" do
      xml = Plist.plist(@opts)

      assert xml =~ "<key>RunAtLoad</key>\n  <true/>"

      assert xml =~
               "<key>KeepAlive</key>\n  <dict>\n    <key>SuccessfulExit</key>\n    <false/>\n  </dict>"

      assert xml =~ "<key>ThrottleInterval</key>\n  <integer>10</integer>"
    end

    test "abandons the process group so detached sessions survive a restart (P3-1)" do
      assert Plist.plist(@opts) =~ "<key>AbandonProcessGroup</key>\n  <true/>"
    end

    test "stdout and stderr go to ~/.wardmast/log/wardmast.log" do
      xml = Plist.plist(@opts)
      log = "/Users/me/.wardmast/log/wardmast.log"

      assert xml =~ "<key>StandardOutPath</key>\n  <string>#{log}</string>"
      assert xml =~ "<key>StandardErrorPath</key>\n  <string>#{log}</string>"
    end

    test "environment carries ARB_HOME, a Homebrew-aware PATH, and forwarded vars" do
      xml = Plist.plist(@opts)

      assert xml =~ "<key>ARB_HOME</key>\n    <string>/Users/me/dev/wardmast</string>"
      assert xml =~ "<key>WARDMAST_HOST</key>\n    <string>http://localhost:4848</string>"
      assert xml =~ "<key>PATH</key>\n    <string>/opt/homebrew/bin:/usr/local/bin:"
    end

    test "environment carries WARDMAST_SERVER_LOG equal to StandardOutPath" do
      xml = Plist.plist(@opts)
      log = "/Users/me/.wardmast/log/wardmast.log"

      assert xml =~ "<key>WARDMAST_SERVER_LOG</key>\n    <string>#{log}</string>"
    end

    test "WARDMAST_SERVER_LOG follows a non-default data home" do
      xml = Plist.plist(arbiter_home: "/Volumes/d/wm")
      log = Plist.log_path("/Volumes/d/wm")

      assert xml =~ "<key>WARDMAST_SERVER_LOG</key>\n    <string>#{log}</string>"
      assert xml =~ "<key>StandardOutPath</key>\n  <string>#{log}</string>"
    end

    test "XML-escapes values" do
      xml = Plist.plist(Keyword.put(@opts, :env, [{"X", ~s(a&b<c>"d")}]))

      assert xml =~ ~s(<string>a&amp;b&lt;c&gt;"d"</string>)

      refute xml =~ "a&b<c>"
    end
  end

  describe "release mode (no :root)" do
    @release_opts [arbiter_home: "/Users/me/.wardmast", env: [{"WARDMAST_HOST", "http://h"}]]

    test "plist runs the same wrapper from the data home, not a checkout" do
      xml = Plist.plist(@release_opts)

      assert xml =~ "<string>/Users/me/.wardmast/launchd-run.sh</string>"
      assert xml =~ "<key>WorkingDirectory</key>\n  <string>/Users/me/.wardmast</string>"
      assert xml =~ "<key>WARDMAST_HOST</key>\n    <string>http://h</string>"
      refute xml =~ "ARB_HOME"
      assert xml =~ "<key>RunAtLoad</key>\n  <true/>"
    end

    test "wrapper loads wardmast.env then execs current/bin/wardmast start" do
      script = Plist.wrapper_script(@release_opts)

      assert script =~ "env_file='/Users/me/.wardmast/wardmast.env'"
      assert script =~ "cd '/Users/me/.wardmast'"
      assert script =~ "exec '/Users/me/.wardmast/current/bin/wardmast' start"
      refute script =~ ".run-server.sh"
    end

    test "the exec target resolves through the current symlink on every start" do
      tmp = Path.join(System.tmp_dir!(), "arb-plist-rel-#{System.unique_integer([:positive])}")
      home = Path.join(tmp, "home")
      out = Path.join(tmp, "out.txt")
      rel = Path.join([home, "releases", "v1", "bin"])
      File.mkdir_p!(rel)
      on_exit(fn -> File.rm_rf(tmp) end)

      File.write!(Path.join(rel, "wardmast"), ~s(#!/bin/sh\necho "$1 $SECRET" > '#{out}'\n))
      File.chmod!(Path.join(rel, "wardmast"), 0o755)
      File.ln_s!(Path.join(home, "releases/v1"), Path.join(home, "current"))
      File.write!(Path.join(home, "wardmast.env"), "SECRET=s3cret\n")

      wrapper = Path.join(home, "launchd-run.sh")
      File.write!(wrapper, Plist.wrapper_script(arbiter_home: home))
      assert {_out, 0} = System.cmd("/bin/sh", [wrapper], stderr_to_stdout: true)
      assert File.read!(out) == "start s3cret\n"
    end
  end

  describe "data home pin (bd-56wi24)" do
    setup do
      prior = {System.get_env("WARDMAST_DATA_HOME"), System.get_env("ARB_DATA_HOME")}
      System.delete_env("WARDMAST_DATA_HOME")
      System.delete_env("ARB_DATA_HOME")

      on_exit(fn ->
        {w, a} = prior
        restore_env("WARDMAST_DATA_HOME", w)
        restore_env("ARB_DATA_HOME", a)
      end)
    end

    defp restore_env(key, nil), do: System.delete_env(key)
    defp restore_env(key, value), do: System.put_env(key, value)

    defp env_entry(key, value), do: "<key>#{key}</key>\n    <string>#{value}</string>"

    test "the release agent plist exports WARDMAST_DATA_HOME and ARB_DATA_HOME = arbiter_home" do
      xml = Plist.plist(arbiter_home: "/Volumes/s/.wardmast")

      assert xml =~ env_entry("WARDMAST_DATA_HOME", "/Volumes/s/.wardmast")
      assert xml =~ env_entry("ARB_DATA_HOME", "/Volumes/s/.wardmast")

      # never pin HOME: it also locates ~/.claude, git config, Library paths
      refute xml =~ "<key>HOME</key>"
    end

    test "the daemon plist exports the data home next to its HOME pin" do
      xml =
        Plist.plist(
          mode: :daemon,
          user_name: "_wardmast",
          user_home: "/Users/_wardmast",
          arbiter_home: "/Users/_wardmast/.wardmast"
        )

      assert xml =~ env_entry("WARDMAST_DATA_HOME", "/Users/_wardmast/.wardmast")
      assert xml =~ env_entry("ARB_DATA_HOME", "/Users/_wardmast/.wardmast")
      assert xml =~ env_entry("HOME", "/Users/_wardmast")
    end

    test "the dev plist does not export it, and a dev ARB_HOME never leaks into it" do
      xml = Plist.plist(@opts)

      refute xml =~ "WARDMAST_DATA_HOME"
      refute xml =~ "ARB_DATA_HOME"
      assert xml =~ env_entry("ARB_HOME", "/Users/me/dev/wardmast")
    end

    test "the dev plist exports it only when WARDMAST_DATA_HOME was set explicitly" do
      System.put_env("WARDMAST_DATA_HOME", "/Volumes/explicit/wm")
      xml = Plist.plist(@opts)

      assert xml =~ env_entry("WARDMAST_DATA_HOME", "/Volumes/explicit/wm")
      assert xml =~ env_entry("ARB_DATA_HOME", "/Volumes/explicit/wm")
      assert xml =~ env_entry("ARB_HOME", "/Users/me/dev/wardmast")
    end
  end

  describe "daemon mode (system-wide LaunchDaemon)" do
    @daemon_opts [
      mode: :daemon,
      user_name: "_wardmast",
      group_name: "staff",
      user_home: "/Users/_wardmast",
      arbiter_home: "/Users/_wardmast/.wardmast",
      env: [{"WARDMAST_HOST", "http://h"}]
    ]

    test "runs as the service account: UserName and GroupName are set" do
      xml = Plist.plist(@daemon_opts)

      assert xml =~ "<key>UserName</key>\n  <string>_wardmast</string>"
      assert xml =~ "<key>GroupName</key>\n  <string>staff</string>"
    end

    test "the agent plist carries no UserName (launchd runs it as the login user)" do
      refute Plist.plist(@opts) =~ "UserName"
      refute Plist.plist(@opts) =~ "GroupName"
    end

    test "UserName is required for a daemon: a root-run server is never generated by accident" do
      assert_raise KeyError, fn ->
        Plist.plist(Keyword.delete(@daemon_opts, :user_name))
      end
    end

    test "logs go under /Library/Logs/Wardmast, not the user's data home" do
      xml = Plist.plist(@daemon_opts)
      log = "/Library/Logs/Wardmast/wardmast.log"

      assert Plist.daemon_log_path() == log
      assert xml =~ "<key>StandardOutPath</key>\n  <string>#{log}</string>"
      assert xml =~ "<key>StandardErrorPath</key>\n  <string>#{log}</string>"
      refute xml =~ ".wardmast/log"
    end

    test "starts at boot and restarts after a failed exit, like the agent" do
      xml = Plist.plist(@daemon_opts)

      assert xml =~ "<key>RunAtLoad</key>\n  <true/>"
      assert xml =~ "<key>SuccessfulExit</key>\n    <false/>"
      assert xml =~ "<key>AbandonProcessGroup</key>\n  <true/>"
    end

    test "environment pins HOME/USER/LOGNAME to the service account" do
      xml = Plist.plist(@daemon_opts)

      assert xml =~ "<key>HOME</key>\n    <string>/Users/_wardmast</string>"
      assert xml =~ "<key>USER</key>\n    <string>_wardmast</string>"
      assert xml =~ "<key>LOGNAME</key>\n    <string>_wardmast</string>"
      assert xml =~ "<key>WARDMAST_HOST</key>\n    <string>http://h</string>"
    end

    test "runs the release wrapper from the service account's data home" do
      xml = Plist.plist(@daemon_opts)

      assert xml =~ "<string>/Users/_wardmast/.wardmast/launchd-run.sh</string>"
      assert xml =~ "<key>WorkingDirectory</key>\n  <string>/Users/_wardmast/.wardmast</string>"
      refute xml =~ "ARB_HOME"
    end

    test "XML-escapes the account name" do
      xml = Plist.plist(Keyword.put(@daemon_opts, :user_name, "a&b"))
      assert xml =~ "<key>UserName</key>\n  <string>a&amp;b</string>"
    end

    test "daemon_dir/0 is /Library/LaunchDaemons" do
      assert Plist.daemon_dir() == "/Library/LaunchDaemons"
    end
  end

  defp wrapper_dirs do
    tmp = Path.join(System.tmp_dir!(), "arb-plist-wrap-#{System.unique_integer([:positive])}")
    root = Path.join(tmp, "checkout")
    home = Path.join(tmp, "home")
    File.mkdir_p!(root)
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(tmp) end)
    {root, home}
  end

  defp run_wrapper(root, home) do
    wrapper = Path.join(home, "launchd-run.sh")
    File.write!(wrapper, Plist.wrapper_script(root: root, arbiter_home: home))
    assert {_out, 0} = System.cmd("/bin/sh", [wrapper], stderr_to_stdout: true)
  end

  describe "wrapper_script/1" do
    test "loads wardmast.env literally, cd's to the root, and execs .run-server.sh" do
      script = Plist.wrapper_script(@opts)

      assert String.starts_with?(script, "#!/bin/sh\n")
      assert script =~ "env_file='/Users/me/.wardmast/wardmast.env'"
      refute script =~ ". '/Users/me/.wardmast/wardmast.env'"
      assert script =~ "cd '/Users/me/dev/wardmast'"
      assert script =~ "exec /bin/sh '/Users/me/dev/wardmast/.run-server.sh'"
    end

    test "tolerates a missing env file and single quotes in paths" do
      script = Plist.wrapper_script(Keyword.put(@opts, :arbiter_home, "/Users/o'neil/.wardmast"))

      assert script =~ ~s(env_file='/Users/o'\\''neil/.wardmast/wardmast.env')
      assert script =~ ~s([ -f "$env_file" ])
    end

    test "running the wrapper exports systemd-style lines literally" do
      {root, home} = wrapper_dirs()
      out = Path.join(root, "out.txt")

      File.write!(Path.join(root, ".run-server.sh"), """
      {
        printf 'PATH=%s\\n' "$PATH"
        printf 'SECRET=%s\\n' "$SECRET"
        printf 'ODD=%s\\n' "$ODD"
        printf 'SKIPPED=%s\\n' "${SKIPPED-unset}"
      } > '#{out}'
      """)

      File.write!(Path.join(home, "wardmast.env"), """
      # comment
      PATH=/Applications/Visual Studio Code.app/Contents/Resources/app/bin:/usr/bin:/bin

      SECRET=pa$$word `echo pwned` $(echo pwned) a;b #not-a-comment
      ODD=trailing=equals=kept
      bad-name=ignored
      SKIPPED
      """)

      run_wrapper(root, home)

      lines = out |> File.read!() |> String.split("\n", trim: true)

      assert "PATH=/Applications/Visual Studio Code.app/Contents/Resources/app/bin:/usr/bin:/bin" in lines
      assert "SECRET=pa$$word `echo pwned` $(echo pwned) a;b #not-a-comment" in lines
      assert "ODD=trailing=equals=kept" in lines
      assert "SKIPPED=unset" in lines
    end

    test "a missing env file is fine" do
      {root, home} = wrapper_dirs()
      File.write!(Path.join(root, ".run-server.sh"), "exit 0\n")

      run_wrapper(root, home)
    end
  end

  test "wrapper_path/1 lives in the arbiter home" do
    assert Plist.wrapper_path("/Users/me/.wardmast") == "/Users/me/.wardmast/launchd-run.sh"
  end
end

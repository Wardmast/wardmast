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

    test "phase 1 does not abandon the process group" do
      assert Plist.plist(@opts) =~ "<key>AbandonProcessGroup</key>\n  <false/>"
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

    test "XML-escapes values" do
      xml = Plist.plist(Keyword.put(@opts, :env, [{"X", ~s(a&b<c>"d")}]))

      assert xml =~ ~s(<string>a&amp;b&lt;c&gt;"d"</string>)

      refute xml =~ "a&b<c>"
    end
  end

  describe "wrapper_script/1" do
    test "sources wardmast.env with allexport, cd's to the root, and execs .run-server.sh" do
      script = Plist.wrapper_script(@opts)

      assert String.starts_with?(script, "#!/bin/sh\n")
      assert script =~ "set -a"
      assert script =~ ". '/Users/me/.wardmast/wardmast.env'"
      assert script =~ "set +a"
      assert script =~ "cd '/Users/me/dev/wardmast'"
      assert script =~ "exec /bin/sh '/Users/me/dev/wardmast/.run-server.sh'"
    end

    test "tolerates a missing env file and single quotes in paths" do
      script = Plist.wrapper_script(Keyword.put(@opts, :arbiter_home, "/Users/o'neil/.wardmast"))

      assert script =~ ~s([ -f '/Users/o'\\''neil/.wardmast/wardmast.env' ])
    end
  end

  test "wrapper_path/1 lives in the arbiter home" do
    assert Plist.wrapper_path("/Users/me/.wardmast") == "/Users/me/.wardmast/launchd-run.sh"
  end
end

defmodule Wardmast.Screenshots.Capture.Sandbox.BwrapTest do
  @moduledoc """
  The capture sandbox's bwrap argv (bd-bhrsdv), built against a fixed host description so it
  runs anywhere. `capture_sandbox_test.exs` runs the same argv for real.
  """

  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture.Sandbox.Bwrap

  @host %{
    tools: %{
      bwrap: "/usr/bin/bwrap",
      perl: "/usr/bin/perl",
      socat: "/usr/bin/socat",
      sh: "/usr/bin/sh"
    },
    system: [
      {"/usr", :dir},
      {"/bin", {:symlink, "usr/bin"}},
      {"/lib64", {:symlink, "usr/lib64"}},
      {"/sbin", :dir}
    ],
    secret_files: ["/home/op/.wardmast/wardmast.env", "/srv/app/releases/COOKIE"],
    mask_dirs: ["/home/op/.wardmast/run", "/run/user/1000"]
  }

  @box %{
    checkout: "/tmp/cap/work/before/checkout",
    scratch: "/tmp/cap/work/before/scratch-default",
    readonly_paths: []
  }

  @app %{port: 32_123, socket: "/tmp/arb-1/cap-x/s", dir: "/tmp/arb-1/cap-x"}

  # Every `{flag, source}` a mount option names, in order.
  defp mounts(argv) do
    argv
    |> Enum.take_while(&(&1 != "--"))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [flag, _] -> flag in ~w(--bind --ro-bind --ro-bind-try --bind-try) end)
    |> Enum.map(fn [flag, src] -> {flag, src} end)
  end

  defp seq?(argv, seq), do: Enum.chunk_every(argv, length(seq), 1, :discard) |> Enum.member?(seq)
  defp index(argv, seq), do: Enum.find_index(Enum.chunk_every(argv, length(seq), 1), &(&1 == seq))

  describe "command_argv/4: an app command (setup, seed)" do
    setup do
      %{argv: Bwrap.command_argv(["sh", "-c", "mix setup"], @box, nil, @host)}
    end

    test "unshares every namespace, the network included, and never shares one back", %{
      argv: argv
    } do
      assert hd(argv) == "/usr/bin/bwrap"
      assert "--unshare-all" in argv
      refute "--share-net" in argv
      assert "--die-with-parent" in argv
      assert "--new-session" in argv
    end

    test "shows the system read-only and the boot's own dirs writable, and nothing else", %{
      argv: argv
    } do
      assert seq?(argv, ["--ro-bind", "/usr", "/usr"])
      assert seq?(argv, ["--ro-bind", "/sbin", "/sbin"])
      assert seq?(argv, ["--symlink", "usr/bin", "/bin"])
      assert seq?(argv, ["--symlink", "usr/lib64", "/lib64"])
      assert seq?(argv, ["--ro-bind", "/etc", "/etc"])
      assert seq?(argv, ["--bind", @box.checkout, @box.checkout])
      assert seq?(argv, ["--bind", @box.scratch, @box.scratch])

      # The allowlist is the whole story: no `/`, no home, no runtime dir, no /tmp of the host.
      sources = argv |> mounts() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
      assert sources == Enum.sort(["/usr", "/sbin", "/etc", @box.checkout, @box.scratch])
    end

    test "private /tmp, /run and /dev/shm come before the boot's dirs, so a checkout under /tmp survives",
         %{argv: argv} do
      for tmpfs <- ["/tmp", "/run", "/dev/shm", "/var/tmp"],
          do: assert(seq?(argv, ["--tmpfs", tmpfs]), "no private #{tmpfs}")

      assert seq?(argv, ["--proc", "/proc"])
      assert seq?(argv, ["--dev", "/dev"])
      assert index(argv, ["--tmpfs", "/tmp"]) < index(argv, ["--bind", @box.checkout])
    end

    test "runs the command from the checkout, after one `--`", %{argv: argv} do
      assert seq?(argv, ["--chdir", @box.checkout, "--", "sh", "-c", "mix setup"])
      assert Enum.take(argv, -3) == ["sh", "-c", "mix setup"]
    end
  end

  describe "command_argv/4: readonly_paths and the server's secrets" do
    test "an operator's readonly path is shown read-only, with ~ expanded" do
      box = %{@box | readonly_paths: ["~/.asdf", "/opt/erlang"]}
      argv = Bwrap.command_argv(["true"], box, nil, @host)
      asdf = Path.expand("~/.asdf")

      assert seq?(argv, ["--ro-bind-try", asdf, asdf])
      assert seq?(argv, ["--ro-bind-try", "/opt/erlang", "/opt/erlang"])
      # read-only before the writable binds, so a checkout inside one stays writable
      assert index(argv, ["--ro-bind-try", "/opt/erlang"]) <
               index(argv, ["--bind", @box.checkout])
    end

    test "a server secret under a shown path is blanked, after every bind; others are not named" do
      box = %{@box | readonly_paths: ["/home/op"]}
      argv = Bwrap.command_argv(["true"], box, nil, @host)

      assert seq?(argv, ["--ro-bind", "/dev/null", "/home/op/.wardmast/wardmast.env"])
      assert seq?(argv, ["--tmpfs", "/home/op/.wardmast/run"])

      assert index(argv, ["--ro-bind", "/dev/null"]) > index(argv, ["--bind", @box.scratch])
      refute "/srv/app/releases/COOKIE" in argv
      refute "/run/user/1000" in argv
    end
  end

  describe "command_argv/4: the started app" do
    setup do
      %{argv: Bwrap.command_argv(["sh", "-c", "mix phx.server"], @box, @app, @host)}
    end

    test "the host creates the listening socket and hands it in, so the app never sees its path",
         %{argv: argv} do
      assert [perl, "-e", listen, socket, bwrap | _] = argv
      assert perl == "/usr/bin/perl"
      assert listen =~ "listen("
      assert socket == @app.socket
      assert bwrap == "/usr/bin/bwrap"

      # Nothing of the socket's directory is mounted inside: the app cannot swap the socket for
      # a symlink that would steer the host's probes into another host socket.
      refute Enum.any?(mounts(argv), fn {_flag, src} -> String.starts_with?(src, @app.dir) end)
    end

    test "a relay inside forwards the inherited socket to the app's loopback port", %{argv: argv} do
      after_sep = argv |> Enum.drop_while(&(&1 != "--")) |> tl()

      assert [
               "/usr/bin/sh",
               "-c",
               relay_sh,
               "sh",
               "/usr/bin/perl",
               relay,
               "32123",
               "/usr/bin/socat",
               "sh",
               "-c",
               "mix phx.server"
             ] = after_sep

      assert relay_sh =~ "3<&-"
      assert relay =~ "accept("
      assert relay =~ "TCP:127.0.0.1:"
    end
  end

  describe "browser_argv/4" do
    setup do
      shot = "/tmp/cap/work/after/shots/7"

      %{
        shot: shot,
        argv:
          Bwrap.browser_argv(
            ["/opt/google/chrome/chrome", "--headless=new", "http://127.0.0.1:32123/"],
            @app,
            [shot],
            @host
          )
      }
    end

    test "is its own sandbox: no network, only the app's socket, its own dir and the browser", %{
      argv: argv,
      shot: shot
    } do
      assert hd(argv) == "/usr/bin/bwrap"
      assert "--unshare-all" in argv
      refute "--share-net" in argv
      assert seq?(argv, ["--ro-bind", @app.socket, @app.socket])
      assert seq?(argv, ["--bind", shot, shot])
      assert seq?(argv, ["--ro-bind", "/opt/google/chrome", "/opt/google/chrome"])

      sources = argv |> mounts() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

      assert sources ==
               Enum.sort([
                 "/usr",
                 "/sbin",
                 "/etc",
                 "/var/cache/fontconfig",
                 "/opt/google/chrome",
                 shot,
                 @app.socket
               ])

      refute @box.checkout in argv
    end

    test "bridges 127.0.0.1:<port> to the app's socket before the browser starts", %{argv: argv} do
      after_sep = argv |> Enum.drop_while(&(&1 != "--")) |> tl()

      assert ["/usr/bin/sh", "-c", bridge, "sh", "/usr/bin/socat", socket, "32123" | browser] =
               after_sep

      assert socket == @app.socket
      assert bridge =~ "TCP-LISTEN:"
      assert bridge =~ "UNIX-CONNECT:"
      assert browser == ["/opt/google/chrome/chrome", "--headless=new", "http://127.0.0.1:32123/"]
    end

    test "a browser under the system dirs needs no extra bind" do
      argv = Bwrap.browser_argv(["/usr/lib/chromium/chromium"], @app, ["/s"], @host)
      refute "/usr/lib/chromium" in argv
    end
  end

  describe "judge_probe/1" do
    @good "if:lo\nroutes:0\ncanary:hidden\nwrite:ok\n"

    test "a namespace with only lo, no route, no host files and a writable checkout passes" do
      assert Bwrap.judge_probe({@good, 0}) == :ok
    end

    test "another interface or a route is a network leak" do
      assert {:error, {:netns_leaks, "eth0"}} =
               Bwrap.judge_probe({"if:lo\nif:eth0\nroutes:0\ncanary:hidden\nwrite:ok\n", 0})

      assert {:error, {:netns_leaks, _}} =
               Bwrap.judge_probe({"if:lo\nroutes:2\ncanary:hidden\nwrite:ok\n", 0})
    end

    test "a host file read from inside is a filesystem leak" do
      assert {:error, {:fs_leaks, _}} =
               Bwrap.judge_probe({"if:lo\nroutes:0\ncanary:visible\nwrite:ok\n", 0})
    end

    test "a checkout it cannot write, or bwrap failing, is not a usable sandbox" do
      assert {:error, {:probe_failed, 0, _}} =
               Bwrap.judge_probe({"if:lo\nroutes:0\ncanary:hidden\n", 0})

      assert {:error, {:probe_failed, 1, "bwrap: No permissions to create new namespace"}} =
               Bwrap.judge_probe({"bwrap: No permissions to create new namespace\n", 1})
    end
  end

  describe "describe/1" do
    test "names each cause in words an operator can act on" do
      assert Bwrap.describe({:tool_not_found, "bwrap", "/nope/bwrap"}) =~ "bwrap"
      assert Bwrap.describe({:tool_not_found, "socat", nil}) =~ "socat"
      assert Bwrap.describe({:netns_leaks, "eth0"}) =~ "network"
      assert Bwrap.describe({:fs_leaks, "canary:visible"}) =~ "host files"
      assert Bwrap.describe({:probe_failed, 1, "boom"}) =~ "boom"
      assert Bwrap.describe(:probe_timeout) =~ "timed out"
      assert Bwrap.describe(:disabled_by_config) =~ "capture_sandbox_available"
    end
  end
end

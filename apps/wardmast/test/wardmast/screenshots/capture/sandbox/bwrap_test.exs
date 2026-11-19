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

    test "a server secret under a shown path is blanked; others are not named" do
      box = %{@box | readonly_paths: ["/home/op"]}
      argv = Bwrap.command_argv(["true"], box, nil, @host)

      assert seq?(argv, ["--ro-bind", "/dev/null", "/home/op/.wardmast/wardmast.env"])
      assert seq?(argv, ["--tmpfs", "/home/op/.wardmast/run"])

      # after the listed path (to hide what it shows), before the boot's own dirs (which a mask
      # over one of their parents must not hide)
      assert index(argv, ["--ro-bind", "/dev/null"]) > index(argv, ["--ro-bind-try", "/home/op"])
      assert index(argv, ["--ro-bind", "/dev/null"]) < index(argv, ["--bind", @box.checkout])
      refute "/srv/app/releases/COOKIE" in argv
      refute "/run/user/1000" in argv
    end

    test "Wardmast's own dirs under a listed path are hidden, and a checkout inside one still shows" do
      worktrees = "/home/op/dev/arbiter-worktrees"
      host = %{@host | mask_dirs: [worktrees | @host.mask_dirs]}

      box = %{
        checkout: worktrees <> "/cap/before/checkout",
        scratch: worktrees <> "/cap/before/scratch",
        readonly_paths: ["/home/op/dev"]
      }

      argv = Bwrap.command_argv(["true"], box, nil, host)

      assert seq?(argv, ["--tmpfs", worktrees])
      assert index(argv, ["--tmpfs", worktrees]) < index(argv, ["--bind", box.checkout])
      assert index(argv, ["--tmpfs", worktrees]) < index(argv, ["--bind", box.scratch])
    end
  end

  describe "own_roots/0" do
    test "names the sockets, trees and data the server keeps, so a listed path cannot show them" do
      roots = Bwrap.own_roots()

      for root <- [
            Wardmast.Config.Paths.socket_root(),
            Wardmast.Config.Paths.scratch_root(),
            Wardmast.Config.Paths.worktree_root(),
            Wardmast.Config.Paths.accounts_root()
          ],
          do: assert(Path.expand(root) in roots, "#{root} is not masked")
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

  # bd-3glf2a: a boot's service containers, reached through host sockets the services layer made.
  describe "command_argv/4: services" do
    @services [
      %{
        name: "postgres",
        port: 5432,
        socket: "/run/user/1000/arbiter/svc-ab12/postgres",
        sandbox_socket: "/run/postgresql/.s.PGSQL.5432"
      },
      %{name: "s3", port: 9000, socket: "/run/user/1000/arbiter/svc-ab12/s3", sandbox_socket: nil}
    ]

    defp services_box, do: Map.put(@box, :services, @services)

    test "each service's host socket is shown read-only at its own path, after the masks" do
      argv = Bwrap.command_argv(["sh", "-c", "mix ecto.setup"], services_box(), nil, @host)

      for svc <- @services do
        assert seq?(argv, ["--ro-bind", svc.socket, svc.socket])
      end

      # /run/user/1000 is a mask dir of the host; the binds are re-opened after it, and nothing
      # else of the socket's directory is mounted.
      refute Enum.any?(mounts(argv), fn {_f, src} -> src == "/run/user/1000/arbiter/svc-ab12" end)

      assert index(argv, ["--ro-bind", hd(@services).socket, hd(@services).socket]) >
               index(argv, ["--tmpfs", "/run"])
    end

    test "a declared socket path also shows the service there" do
      argv = Bwrap.command_argv(["true"], services_box(), nil, @host)

      assert seq?(argv, [
               "--ro-bind",
               "/run/user/1000/arbiter/svc-ab12/postgres",
               "/run/postgresql/.s.PGSQL.5432"
             ])
    end

    test "a relay per service listens on 127.0.0.1:<port> before the command runs" do
      argv = Bwrap.command_argv(["sh", "-c", "mix ecto.setup"], services_box(), nil, @host)
      after_sep = argv |> Enum.drop_while(&(&1 != "--")) |> tl()

      assert [
               "/usr/bin/sh",
               "-c",
               services_sh,
               "sh",
               "/usr/bin/socat",
               "5432",
               "/run/user/1000/arbiter/svc-ab12/postgres",
               "9000",
               "/run/user/1000/arbiter/svc-ab12/s3",
               "--",
               "sh",
               "-c",
               "mix ecto.setup"
             ] = after_sep

      assert services_sh =~ "TCP-LISTEN:"
      assert services_sh =~ "bind=127.0.0.1"
      assert services_sh =~ "UNIX-CONNECT:"
      # The relays never hold the app's inherited listening socket.
      assert services_sh =~ "3<&-"
      assert services_sh =~ "/proc/net/tcp"
    end

    test "the started app gets the services first, then its own relay" do
      argv = Bwrap.command_argv(["sh", "-c", "mix phx.server"], services_box(), @app, @host)
      after_sep = argv |> Enum.drop_while(&(&1 != "--")) |> tl()

      assert ["/usr/bin/sh", "-c", services_sh, "sh", "/usr/bin/socat" | rest] = after_sep
      assert services_sh =~ "TCP-LISTEN:"
      assert ["5432", _, "9000", _, "--", "/usr/bin/sh", "-c", relay_sh | _] = rest
      assert relay_sh =~ "exec 3<&-"
      assert List.last(argv) == "mix phx.server"
    end

    test "no services: the argv is unchanged" do
      plain = Bwrap.command_argv(["true"], @box, nil, @host)
      assert Bwrap.command_argv(["true"], Map.put(@box, :services, []), nil, @host) == plain
    end

    test "the browser never sees a service" do
      argv = Bwrap.browser_argv(["/usr/bin/chromium"], @app, ["/tmp/shot"], @host)
      refute Enum.any?(argv, &String.contains?(&1, "svc-ab12"))
    end
  end

  # bd-3glf2a: the deps cache a boot is pointed at.
  describe "command_argv/4: cache dirs" do
    test "are shown read-only, after the masks, and never writable" do
      box = Map.put(@box, :cache_dirs, ["/home/op/.cache/arbiter/scratch/capture-deps/abc-def"])
      argv = Bwrap.command_argv(["true"], box, nil, @host)
      dir = "/home/op/.cache/arbiter/scratch/capture-deps/abc-def"

      assert seq?(argv, ["--ro-bind", dir, dir])
      refute seq?(argv, ["--bind", dir, dir])
    end
  end

  # bd-3glf2a: trusted, default-branch code (the deps cache seed) with the network on.
  describe "fetch_argv/3" do
    test "shares the network and nothing else back, with the same filesystem allowlist" do
      argv = Bwrap.fetch_argv(["sh", "-c", "mix deps.get"], @box, @host)
      plain = Bwrap.command_argv(["sh", "-c", "mix deps.get"], @box, nil, @host)

      assert hd(argv) == "/usr/bin/bwrap"
      assert "--unshare-all" in argv
      assert "--share-net" in argv
      # The one difference from an app command: the network.
      assert List.delete(argv, "--share-net") == plain
      assert seq?(argv, ["--bind", @box.checkout, @box.checkout])
      assert Enum.take(argv, -3) == ["sh", "-c", "mix deps.get"]
    end

    test "a resolv.conf that points into /run is shown, so names resolve" do
      host = Map.put(@host, :resolv_conf, "/run/systemd/resolve/stub-resolv.conf")
      argv = Bwrap.fetch_argv(["true"], @box, host)

      assert seq?(argv, [
               "--ro-bind-try",
               "/run/systemd/resolve/stub-resolv.conf",
               "/run/systemd/resolve/stub-resolv.conf"
             ])

      refute seq?(Bwrap.command_argv(["true"], @box, nil, host), [
               "--ro-bind-try",
               "/run/systemd/resolve/stub-resolv.conf",
               "/run/systemd/resolve/stub-resolv.conf"
             ])
    end
  end

  describe "browser_argv/4,5" do
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

    test "read-only extras (a runner's own dir, a browser binary) are shown beside the executable" do
      argv =
        Bwrap.browser_argv(
          ["/opt/node/bin/node", "/opt/arbiter/capture/runner.mjs"],
          @app,
          ["/s"],
          ["/opt/arbiter/capture", "/usr/lib/chromium", "/opt/node/bin"],
          @host
        )

      assert seq?(argv, ["--ro-bind", "/opt/node/bin", "/opt/node/bin"])
      assert seq?(argv, ["--ro-bind", "/opt/arbiter/capture", "/opt/arbiter/capture"])
      # under the system dirs already: no extra bind; and each is bound once
      refute seq?(argv, ["--ro-bind", "/usr/lib/chromium", "/usr/lib/chromium"])
      assert Enum.count(mounts(argv), &(elem(&1, 1) == "/opt/node/bin")) == 1
      # none of them is writable
      refute seq?(argv, ["--bind", "/opt/arbiter/capture", "/opt/arbiter/capture"])
    end

    test "browser/3 is browser/4 with nothing extra" do
      assert Bwrap.browser_argv(["/opt/b/chrome"], @app, ["/s"], @host) ==
               Bwrap.browser_argv(["/opt/b/chrome"], @app, ["/s"], [], @host)
    end

    test "a browser reached through a symlinked system dir (merged /usr) needs none either" do
      # /bin is a symlink to usr/bin inside the sandbox too; binding over it would fight the link
      argv = Bwrap.browser_argv(["/bin/chromium"], @app, ["/s"], @host)
      refute seq?(argv, ["--ro-bind", "/bin", "/bin"])
      assert seq?(argv, ["--symlink", "usr/bin", "/bin"])
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

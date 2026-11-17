defmodule WardmastCli.Scripts.CheckReleaseDylibsTest do
  @moduledoc """
  Coverage for `scripts/check-release-dylibs.sh`, the macOS counterpart of the
  ELF guard: every Mach-O file in the release may only link system libraries
  (`/usr/lib`, `/System/Library`) or paths relative to itself. A Homebrew
  `/opt/homebrew/.../libcrypto.dylib` dependency would not exist on a user's
  Mac. `otool` is stubbed through `$OTOOL`, so this runs on any host.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/check-release-dylibs.sh", __DIR__)
  # 64-bit little-endian Mach-O magic.
  @macho <<0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0>>

  defp tmp_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "dylib-guard-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A fake otool: `-L` prints "<file>.deps" the way otool -L would (with the
  # file's own install name first when "<file>.id" exists, as for a dylib, and
  # a fat-binary slice header when "<file>.fat" exists); `-D` prints the id.
  defp stub_otool!(dir) do
    path = Path.join(dir, "fake-otool")

    File.write!(path, """
    #!/bin/sh
    # usage: otool -L|-D <file>
    if [ "$1" = "-D" ]; then
      echo "$2:"
      if [ -f "$2.id" ]; then cat "$2.id"; fi
      exit 0
    fi
    if [ -f "$2.fat" ]; then echo "$2 (architecture arm64):"; else echo "$2:"; fi
    if [ -f "$2.id" ]; then printf '\\t%s (compatibility version 0.0.0, current version 0.0.0)\\n' "$(cat "$2.id")"; fi
    cat "$2.deps"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp release!(dir, deps) do
    root = Path.join(dir, "rel")
    File.mkdir_p!(Path.join(root, "lib"))
    file = Path.join(root, "lib/crypto.so")
    File.write!(file, @macho)

    File.write!(
      file <> ".deps",
      Enum.map_join(deps, "", &"\t#{&1} (compatibility version 1.0.0)\n")
    )

    File.write!(Path.join(root, "README.txt"), "not a mach-o file\n")
    root
  end

  defp run(dir, path) do
    System.cmd("bash", [@script, path],
      env: [{"OTOOL", stub_otool!(dir)}],
      stderr_to_stdout: true
    )
  end

  test "passes when a binary only links system libraries" do
    dir = tmp_dir!()

    root =
      release!(dir, [
        "/usr/lib/libSystem.B.dylib",
        "/usr/lib/libncurses.5.4.dylib",
        "/System/Library/Frameworks/Security.framework/Versions/A/Security",
        "@loader_path/libfoo.dylib"
      ])

    assert {out, 0} = run(dir, root)
    assert out =~ "OK"
  end

  test "fails, naming file and library, on a Homebrew dependency" do
    dir = tmp_dir!()

    root =
      release!(dir, [
        "/usr/lib/libSystem.B.dylib",
        "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib"
      ])

    assert {out, 1} = run(dir, root)
    assert out =~ "crypto.so"
    assert out =~ "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib"
  end

  test "ignores a dylib's own install name (absolute build path from -dynamiclib)" do
    dir = tmp_dir!()
    root = release!(dir, ["/usr/lib/libSystem.B.dylib"])

    File.write!(
      Path.join(root, "lib/crypto.so.id"),
      "/Users/runner/work/arbiter/_build/prod/lib/exqlite/priv/sqlite3_nif.so\n"
    )

    assert {out, 0} = run(dir, root)
    assert out =~ "OK"
  end

  test "still fails a Homebrew dependency of a dylib that has its own install name" do
    dir = tmp_dir!()
    root = release!(dir, ["/opt/homebrew/lib/libcrypto.3.dylib"])
    File.write!(Path.join(root, "lib/crypto.so.id"), "/Users/runner/build/crypto.so\n")

    assert {out, 1} = run(dir, root)
    assert out =~ "/opt/homebrew/lib/libcrypto.3.dylib"
    refute out =~ "links /Users/runner"
  end

  test "does not treat fat-binary slice headers as dependencies" do
    dir = tmp_dir!()
    root = release!(dir, ["/usr/lib/libSystem.B.dylib"])
    File.write!(Path.join(root, "lib/crypto.so.fat"), "")

    assert {out, 0} = run(dir, root)
    assert out =~ "OK"
  end

  test "fails when the scan finds no Mach-O files" do
    dir = tmp_dir!()
    empty = Path.join(dir, "empty")
    File.mkdir_p!(empty)
    File.write!(Path.join(empty, "a.txt"), "x")

    assert {out, 1} = run(dir, empty)
    assert out =~ "no Mach-O"
  end

  test "scans a release tarball" do
    dir = tmp_dir!()
    root = release!(dir, ["/usr/local/lib/libfoo.dylib"])
    tarball = Path.join(dir, "rel.tar.gz")
    {_, 0} = System.cmd("tar", ["-czf", tarball, "-C", root, "."])

    assert {out, 1} = run(dir, tarball)
    assert out =~ "/usr/local/lib/libfoo.dylib"
  end
end

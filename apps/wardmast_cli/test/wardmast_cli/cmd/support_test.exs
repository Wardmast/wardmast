defmodule WardmastCli.Cmd.SupportTest do
  @moduledoc "`arb support bundle` writes the server's redacted diagnostics archive to disk."
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Cmd.Support

  test "bundle writes the archive to --out" do
    out = Path.join(System.tmp_dir!(), "bundle-#{System.unique_integer([:positive])}.tar.gz")
    on_exit(fn -> File.rm(out) end)

    stub_get(
      "/api/support/bundle",
      %{"filename" => "arb-support-bundle-x.tar.gz", "data_base64" => Base.encode64("TARBYTES")},
      200
    )

    {stdout, _err, code} = capture(fn -> Support.run(["bundle", "--out", out]) end)

    assert code == 0
    assert File.read!(out) == "TARBYTES"
    assert stdout =~ out
  end

  test "unknown subcommand dies" do
    {_out, err, code} = capture(fn -> Support.run(["nope"]) end)
    assert code != 0
    assert err =~ "bundle"
  end
end

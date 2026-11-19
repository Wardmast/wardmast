defmodule WardmastCli.Cmd.UpdateCheckTest do
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Cmd.Server

  @ok %{
    "latest" => "v0.6.6",
    "running" => "0.6.5",
    "update_available" => true,
    "release_url" => "https://example.test/r/v0.6.6",
    "checked_at" => "2026-11-19T10:00:00Z",
    "cached" => false,
    "error" => nil
  }

  test "prints the result as text and exits 0" do
    stub_post("/api/server/update_check", @ok, 200)
    {out, _err, code} = capture(fn -> Server.run(["update-check"]) end)
    assert code == 0
    assert out =~ "latest:           v0.6.6"
    assert out =~ "update_available: true"
    assert out =~ "release_url:      https://example.test/r/v0.6.6"
    assert out =~ "checked_at:       2026-11-19T10:00:00Z"
  end

  test "--json prints the server's map" do
    stub_post("/api/server/update_check", @ok, 200)
    {out, _err, code} = capture(fn -> Server.run(["update-check", "--json"]) end)
    assert code == 0
    assert %{"latest" => "v0.6.6", "update_available" => true} = Jason.decode!(out)
  end

  test "exits non-zero only when the check errored" do
    stub_post("/api/server/update_check", %{@ok | "error" => "could not reach GitHub"}, 200)
    {_out, err, code} = capture(fn -> Server.run(["update-check"]) end)
    assert code == 1
    assert err =~ "could not reach GitHub"
  end
end

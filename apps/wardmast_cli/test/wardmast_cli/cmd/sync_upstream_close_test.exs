defmodule WardmastCli.Cmd.SyncUpstreamCloseTest do
  use WardmastCli.CliCase, async: true

  alias WardmastCli.Cmd.SyncUpstreamClose

  test "POSTs /api/issues/:id/sync_upstream_close and prints the ticket" do
    stub_routes([
      {{"post", "/api/issues/bd-001/sync_upstream_close"},
       {%{"id" => "bd-001", "title" => "X", "state" => "closed"}, 200}}
    ])

    {out, _err, code} = capture(fn -> SyncUpstreamClose.run(["bd-001"]) end)
    assert code == 0
    assert out =~ "bd-001"
  end

  test "requires an id" do
    {_out, err, code} = capture(fn -> SyncUpstreamClose.run([]) end)
    assert code != 0
    assert err =~ "requires a ticket id"
  end
end

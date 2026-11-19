defmodule WardmastWeb.SessionTranscriptPairTest do
  @moduledoc """
  bd-7p6a9o: a pair session is a visible session kind, so its transcript is
  served like a coordinator session's — only the hidden `:login` relay 404s
  (`WardmastWeb.SessionTranscriptControllerTest`).
  """
  use WardmastWeb.ConnCase, async: false

  alias Wardmast.Sessions
  alias Wardmast.Sessions.Transcript
  alias Wardmast.Test.NoopRunner

  setup do
    Wardmast.Test.SessionEnv.sandbox("transcript-pair")
    :ok
  end

  test "a pair session's transcript is served", %{conn: conn} do
    {:ok, pair} =
      Sessions.launch(
        runner: NoopRunner,
        ensure_reader: false,
        provision: false,
        kind: :pair,
        issue_id: "pt-1",
        workspace_id: "ws-pair"
      )

    :ok = Transcript.append(pair.id, "pair work")

    conn = get(conn, ~p"/sessions/#{pair.id}/transcript")
    assert conn.status == 200
    assert conn.resp_body == "pair work"
  end
end

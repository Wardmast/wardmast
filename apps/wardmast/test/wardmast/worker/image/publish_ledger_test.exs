defmodule Wardmast.Worker.Image.PublishLedgerTest do
  use ExUnit.Case, async: true

  alias Wardmast.Worker.Image.PublishLedger

  @moduletag :tmp_dir

  test "images/1 lists each repo's newest publish with its CLI set, providers and seed", %{
    tmp_dir: tmp
  } do
    opts = [ledger: Path.join(tmp, "ledger.term")]

    facts = %{
      providers: ["claude"],
      clis: [%{name: "claude", version: "2.1.0"}],
      seed: %{status: :pushed, reason: nil}
    }

    PublishLedger.record(
      %{repo: "a", repo_path: "/a"},
      [ref: "r@sha256:old", now: ~U[2026-01-01 00:00:00Z]] ++ opts
    )

    PublishLedger.record(
      %{repo: "a", repo_path: "/a"},
      [ref: "r@sha256:new", image: facts, now: ~U[2026-01-02 00:00:00Z]] ++ opts
    )

    assert [%{repo: "a", ref: "r@sha256:new", providers: ["claude"], seed: %{status: :pushed}}] =
             PublishLedger.images(opts)

    assert PublishLedger.images(ledger: nil) == []
  end

  test "touch: false updates ref and image facts without restarting the 14-day clock", %{
    tmp_dir: tmp
  } do
    opts = [ledger: Path.join(tmp, "ledger.term")]
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = ~U[2026-01-10 00:00:00Z]

    PublishLedger.record(
      %{repo: "a", repo_path: "/a"},
      [ref: "r@sha256:old", now: t0] ++ opts
    )

    PublishLedger.record(
      %{repo: "a", repo_path: "/a"},
      [
        ref: "r@sha256:new",
        image: %{
          providers: ["claude"],
          clis: [%{name: "claude", version: "2.1.311"}],
          seed: %{status: :pushed}
        },
        now: t1,
        touch: false
      ] ++ opts
    )

    assert PublishLedger.last_ref("a", opts) == "r@sha256:new"
    assert [%{repo: "a", ref: "r@sha256:new", at: ^t0}] = PublishLedger.images(opts)
  end
end

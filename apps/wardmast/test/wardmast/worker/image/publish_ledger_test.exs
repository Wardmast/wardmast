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

  describe "pre-rename ledgers (bd-brlxev)" do
    import ExUnit.CaptureLog

    # A ledger written before the rename: a ctx holding an `%Arbiter.Tasks.Workspace{}`.
    # The legacy atom is built by patching a same-length placeholder in the bytes, so it
    # never exists in this VM (as in a freshly booted release).
    defp legacy_ledger(at) do
      workspace = %{__struct__: :"Elixir.Zzzzzzz.Tasks.Workspace", id: "ws-1", config: %{}}

      entry = fn repo ->
        %{
          key: {repo, "/" <> repo},
          ctx: %{repo: repo, repo_path: "/" <> repo, workspace: workspace},
          at: at,
          ref: "r@sha256:" <> repo
        }
      end

      %{{"a", "/a"} => entry.("a"), {"b", "/b"} => entry.("b")}
      |> :erlang.term_to_binary()
      |> :binary.replace("Elixir.Zzzzzzz.Tasks.Workspace", "Elixir.Arbiter.Tasks.Workspace", [
        :global
      ])
    end

    test "recent/2 and last_ref/2 read entries written with Arbiter.* structs", %{tmp_dir: tmp} do
      file = Path.join(tmp, "ledger.term")
      now = ~U[2026-01-02 00:00:00Z]
      File.write!(file, legacy_ledger(now))
      opts = [ledger: file, now: now]

      assert_raise ArgumentError, fn ->
        :erlang.binary_to_term(File.read!(file), [:safe])
      end

      assert [%{ctx: ctx}, _] = PublishLedger.recent(14, opts)
      assert ctx.workspace_id == "ws-1"
      refute Map.has_key?(ctx, :workspace)
      assert PublishLedger.last_ref("a", opts) == "r@sha256:a"
      assert [%{repo: "a"}, %{repo: "b"}] = PublishLedger.images(opts)
    end

    test "an unreadable ledger logs a warning naming the path and keeps the file", %{tmp_dir: tmp} do
      file = Path.join(tmp, "ledger.term")
      File.write!(file, "not a term")

      log =
        capture_log([level: :warning], fn ->
          assert PublishLedger.recent(14, ledger: file) == []
        end)

      assert log =~ file
      assert File.read!(file) == "not a term"
    end

    test "new entries hold no module structs and decode safely", %{tmp_dir: tmp} do
      file = Path.join(tmp, "ledger.term")
      workspace = %Wardmast.Tasks.Workspace{id: "ws-9", config: %{"worker" => %{}}}

      PublishLedger.record(
        %{repo: "a", repo_path: "/a", workspace: workspace, plan: %{tag: "t"}},
        ledger: file,
        ref: "r@sha256:x"
      )

      entries = :erlang.binary_to_term(File.read!(file), [:safe])
      [%{ctx: ctx}] = Map.values(entries)
      assert ctx.workspace_id == "ws-9"
      refute Map.has_key?(ctx, :workspace)
      refute contains_struct?(entries)
    end

    defp contains_struct?(%DateTime{}), do: false
    defp contains_struct?(%{__struct__: _}), do: true
    defp contains_struct?(%{} = m), do: m |> Map.values() |> Enum.any?(&contains_struct?/1)
    defp contains_struct?(l) when is_list(l), do: Enum.any?(l, &contains_struct?/1)
    defp contains_struct?(t) when is_tuple(t), do: t |> Tuple.to_list() |> contains_struct?()
    defp contains_struct?(_), do: false
  end
end

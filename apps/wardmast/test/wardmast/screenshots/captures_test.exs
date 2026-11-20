defmodule Wardmast.Screenshots.CapturesTest do
  @moduledoc "bd-8qj1sa: the durable screenshot_captures record and its lifecycle."
  use Wardmast.DataCase, async: false

  alias Wardmast.Screenshots.Capture.Failure
  alias Wardmast.Screenshots.CaptureRecord
  alias Wardmast.Screenshots.Captures
  alias Wardmast.Screenshots.Config

  @attrs %{
    task_id: "bd-t1",
    workspace_id: "ws-1",
    head_sha: "h1",
    base_sha: "b1",
    plan_hash: "p1",
    config_hash: "c1"
  }

  describe "begin_attempt/1" do
    test "writes a running row with head, base, plan_hash, config_hash" do
      assert {:ok, %CaptureRecord{} = rec} = Captures.begin_attempt(@attrs)
      assert rec.state == "running"

      assert {rec.head_sha, rec.base_sha, rec.plan_hash, rec.config_hash} ==
               {"h1", "b1", "p1", "c1"}

      assert [%{id: id}] = Captures.list("bd-t1")
      assert id == rec.id
    end
  end

  describe "finish/2" do
    test "maps each outcome to a state" do
      {:ok, a} = Captures.begin_attempt(@attrs)

      assert {:ok, %{state: "captured", pair_count: 2}} =
               Captures.finish(a, {:ok, %{pairs: [1, 2]}})

      {:ok, b} = Captures.begin_attempt(%{@attrs | head_sha: "h2"})

      assert {:ok, %{state: "skipped", reason: "no_ui_paths"}} =
               Captures.finish(b, {:skipped, :no_ui_paths})

      {:ok, c} = Captures.begin_attempt(%{@attrs | head_sha: "h3"})
      failure = Failure.new(:boot_failed, "nope")

      assert {:ok, %{state: "failed", failure_code: "boot_failed", reason: "nope"}} =
               Captures.finish(c, {:error, failure})
    end

    test "never overwrites a superseded row" do
      {:ok, a} = Captures.begin_attempt(@attrs)
      assert 1 = Captures.supersede("bd-t1", "h2")
      assert {:ok, %{state: "superseded"}} = Captures.finish(a, {:ok, %{pairs: []}})
    end
  end

  describe "supersede/2" do
    test "cancels running rows for other heads only" do
      {:ok, old} = Captures.begin_attempt(@attrs)
      {:ok, cur} = Captures.begin_attempt(%{@attrs | head_sha: "h2"})
      {:ok, other} = Captures.begin_attempt(%{@attrs | task_id: "bd-other"})

      assert 1 = Captures.supersede("bd-t1", "h2")
      states = Map.new(Captures.list("bd-t1") ++ Captures.list("bd-other"), &{&1.id, &1.state})
      assert states[old.id] == "superseded"
      assert states[cur.id] == "running"
      assert states[other.id] == "running"
    end
  end

  describe "history/1" do
    test "counts booted attempts (not skips or manifest failures) and finds the last captured head" do
      {:ok, a} = Captures.begin_attempt(@attrs)
      Captures.finish(a, {:ok, %{pairs: []}})
      {:ok, b} = Captures.begin_attempt(%{@attrs | head_sha: "h2"})
      Captures.finish(b, {:skipped, :no_ui_paths})
      {:ok, c} = Captures.begin_attempt(%{@attrs | head_sha: "h3"})
      Captures.finish(c, {:error, Failure.new(:boot_failed, "x")})

      {:ok, d} = Captures.begin_attempt(%{@attrs | head_sha: "h4"})
      Captures.finish(d, {:error, Failure.new(:manifest_missing, "no plan")})

      assert %{attempts: 2, last_captured: %{head_sha: "h1"}} = Captures.history("bd-t1")
      assert %{attempts: 0, last_captured: nil} = Captures.history("bd-none")
    end
  end

  describe "hashes" do
    test "config_hash is stable and changes with the config" do
      c1 = %Config{ui_paths: ["a"], start_cmd: "x"}
      c2 = %Config{ui_paths: ["b"], start_cmd: "x"}
      assert Captures.config_hash(c1) == Captures.config_hash(c1)
      refute Captures.config_hash(c1) == Captures.config_hash(c2)
    end

    test "plan_hash reads the file, nil when absent" do
      path = Path.join(System.tmp_dir!(), "plan-#{System.unique_integer([:positive])}.json")
      File.write!(path, "{}")
      on_exit(fn -> File.rm(path) end)
      assert is_binary(Captures.plan_hash(path))
      assert Captures.plan_hash(path <> ".nope") == nil
    end
  end
end

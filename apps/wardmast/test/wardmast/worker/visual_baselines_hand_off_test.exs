defmodule Wardmast.Worker.VisualBaselinesHandOffTest do
  use ExUnit.Case, async: false

  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker.VisualBaselines

  @moduletag :tmp_dir

  defmodule FakeForge do
    @moduledoc false
    def ci_job_artifacts(_mr_ref, _job, _opts),
      do: Application.get_env(:wardmast, :visual_hand_off_artifacts)

    def last_green_job_sha(_mr_ref, _job, _opts), do: {:ok, nil}
  end

  defp zip(files) do
    {:ok, {_, bin}} =
      :zip.create(
        ~c"a.zip",
        Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end),
        [:memory]
      )

    bin
  end

  setup %{tmp_dir: tmp} do
    checkout = Path.join(tmp, "wt")
    File.mkdir_p!(Path.join(checkout, "e2e"))
    File.write!(Path.join(checkout, "e2e/page-chromium-linux.png"), "page-0")
    File.write!(Path.join(checkout, "e2e/other-chromium-linux.png"), "other-0")

    on_exit(fn -> Application.delete_env(:wardmast, :visual_hand_off_artifacts) end)

    workspace = %Workspace{
      id: Ecto.UUID.generate(),
      config: %{
        "repo_paths" => %{"tonic" => checkout},
        "worker" => %{
          "repos" => %{
            "tonic" => %{
              "visual_baselines" => %{
                "job" => "visual",
                "artifact_path" => "test-results",
                "baseline_dir" => "e2e",
                "baseline_suffix" => "-chromium-linux.png"
              }
            }
          }
        }
      }
    }

    ctx = %{
      workspace: workspace,
      repo: "tonic",
      adapter: FakeForge,
      mr_ref: "!7",
      result: %{head_sha: "head1", head_ref: "feature/x", base_ref: "main"}
    }

    %{ctx: ctx, checkout: checkout}
  end

  defp artifacts(sha, failed, files),
    do:
      Application.put_env(
        :wardmast,
        :visual_hand_off_artifacts,
        {:ok, %{sha: sha, failed_jobs: failed, archive: zip(files)}}
      )

  defp dir(checkout), do: Path.join(checkout, ".arbiter/visual-actual")

  test "stages the head's actual and diff images under their baseline names, committing nothing",
       %{ctx: ctx, checkout: checkout} do
    artifacts("head1", ["visual"], [
      {"test-results/a/page-actual.png", "page-1"},
      {"test-results/a/page-diff.png", "page-diff"},
      {"test-results/b/other-actual.png", "other-0"}
    ])

    assert {:ok, [entry]} = VisualBaselines.hand_off(ctx, checkout)
    assert entry.baseline == "e2e/page-chromium-linux.png"
    assert File.read!(Path.join(dir(checkout), "page-chromium-linux.png")) == "page-1"
    assert File.read!(Path.join(dir(checkout), "page-chromium-linux-diff.png")) == "page-diff"
    # an image equal to its baseline is not handed over
    refute File.exists?(Path.join(dir(checkout), "other-chromium-linux.png"))
    # the baseline itself is untouched
    assert File.read!(Path.join(checkout, "e2e/page-chromium-linux.png")) == "page-0"
  end

  test "images from a different head are never handed over", %{ctx: ctx, checkout: checkout} do
    artifacts("older-head", ["visual"], [{"test-results/a/page-actual.png", "stale"}])
    assert {:skip, :artifacts_for_another_head} = VisualBaselines.hand_off(ctx, checkout)
    refute File.exists?(dir(checkout))
  end

  test "stale images from an earlier hand-off are removed", %{ctx: ctx, checkout: checkout} do
    File.mkdir_p!(dir(checkout))
    File.write!(Path.join(dir(checkout), "old-chromium-linux.png"), "old")
    artifacts("older-head", ["visual"], [{"test-results/a/page-actual.png", "stale"}])
    assert {:skip, _} = VisualBaselines.hand_off(ctx, checkout)
    refute File.exists?(dir(checkout))
  end

  test "other failed jobs do not stop the hand-off; a green visual job does",
       %{ctx: ctx, checkout: checkout} do
    artifacts("head1", ["visual", "lint"], [{"test-results/a/page-actual.png", "page-1"}])
    assert {:ok, [_]} = VisualBaselines.hand_off(ctx, checkout)

    artifacts("head1", ["lint"], [{"test-results/a/page-actual.png", "page-1"}])
    assert {:skip, :visual_job_not_failed} = VisualBaselines.hand_off(ctx, checkout)
    refute File.exists?(dir(checkout))
  end

  test "a repo without visual_baselines is a skip", %{ctx: ctx, checkout: checkout} do
    assert {:skip, :not_configured} = VisualBaselines.hand_off(%{ctx | repo: "x"}, checkout)
  end

  test "the brief tells the agent how to use the images, or says they are missing",
       %{ctx: ctx, checkout: checkout} do
    artifacts("head1", ["visual"], [{"test-results/a/page-actual.png", "page-1"}])
    outcome = VisualBaselines.hand_off(ctx, checkout)

    brief = VisualBaselines.hand_off_brief(outcome)
    assert brief =~ ".arbiter/visual-actual/"
    assert brief =~ "e2e/page-chromium-linux.png"
    assert brief =~ "regression"

    missing = VisualBaselines.hand_off_brief({:skip, :artifacts_for_another_head})
    assert missing =~ "could not be delivered"
  end
end

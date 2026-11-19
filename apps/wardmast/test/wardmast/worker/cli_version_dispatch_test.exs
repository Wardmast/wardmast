defmodule Wardmast.Worker.CliVersionDispatchTest do
  @moduledoc """
  bd-5wfsj7: dispatch to a provider whose CLI is below its minimum supported
  version is refused up front with the installed and the required version, not
  failed mid-run. A stub `claude` answers `--version`; nothing real runs.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Agents.CliDetection
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.TestSandbox
  alias Wardmast.Worker.Dispatch
  alias Wardmast.Workers.Run

  require Ash.Query

  @moduletag :linux

  setup do
    claude_credential_env!()

    sandbox = TestSandbox.provision!("cli-version-dispatch")
    put_app_env(:wardmast, :worktree_root, sandbox.worktree_root)
    put_app_env(:wardmast, :repo_paths, %{"pc/repo" => sandbox.repo})

    # A `claude` that only answers `--version`, ahead of the sandbox's stubs.
    bin = Path.join(sandbox.root, "versionbin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "claude"), "#!/bin/sh\necho '1.0.9 (Claude Code)'\n")
    File.chmod!(Path.join(bin, "claude"), 0o755)
    old = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> old)
    on_exit(fn -> System.put_env("PATH", old) end)

    put_app_env(:wardmast, CliDetection, enforce: true, min_versions: %{"claude" => "2.0.0"})
    put_app_env(:wardmast, :harness_version, probe: true)

    on_exit(fn ->
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
      TestSandbox.own_live_workers!(sandbox)
    end)

    :ok
  end

  defp task! do
    n = System.unique_integer([:positive])

    ws =
      Ash.create!(Workspace, %{
        name: "cv-#{n}",
        prefix: "cv#{n}",
        config: %{"agent" => %{"type" => "claude", "config" => %{}}}
      })

    Ash.create!(Issue, %{title: "gate me", workspace_id: ws.id, difficulty: 1})
  end

  test "an outdated claude CLI refuses the dispatch with a clear reason and starts nothing" do
    task = task!()

    assert {:error, {:cli_version, "claude", phrase}} =
             Dispatch.dispatch(task.id,
               force: true,
               repo: "pc/repo",
               start_driver: false,
               start_claude: true,
               preflight: false
             )

    assert phrase =~ "1.0.9"
    assert phrase =~ "2.0.0"
    assert Ash.Query.filter(Run, task_id == ^task.id) |> Ash.read!() == []
    assert Dispatch.refusal_kind({:cli_version, "claude", phrase}) == :conflict
  end

  test "the same CLI at or above the minimum is not refused by the gate" do
    put_app_env(:wardmast, CliDetection, enforce: true, min_versions: %{"claude" => "1.0.0"})
    assert :ok = CliDetection.gate("claude")
  end
end

defmodule Wardmast.Worker.WorkerEnvTest do
  use Wardmast.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker.WorkerEnv

  defp workspace_with_env(worker_env) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "we-#{System.unique_integer([:positive])}",
        worker_env: worker_env
      })

    ws
  end

  defp task_in(ws) do
    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
    task
  end

  describe "pairs/1" do
    test "returns every worker env var (secret and plain) as decrypted pairs" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true},
          "LOG_LEVEL" => %{"value" => "debug", "secret" => false}
        })

      task = task_in(ws)

      assert Enum.sort(WorkerEnv.pairs(task.id)) ==
               [{"API_TOKEN", "tok_secret"}, {"LOG_LEVEL", "debug"}]
    end

    test "returns [] for a workspace with no worker env vars" do
      task = task_in(workspace_with_env(%{}))
      assert WorkerEnv.pairs(task.id) == []
    end

    test "returns [] for an unknown / nil task id" do
      assert WorkerEnv.pairs("does-not-exist") == []
      assert WorkerEnv.pairs(nil) == []
      assert WorkerEnv.pairs("") == []
    end

    test "resolves the same pairs for a ReviewGate synthetic task id as for the base task" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true}
        })

      task = task_in(ws)

      expected = WorkerEnv.resolve(task.id)
      assert expected != {[], []}

      assert WorkerEnv.resolve(task.id <> "#review") == expected
      assert WorkerEnv.resolve(task.id <> "#review#impl1") == expected
      assert WorkerEnv.resolve(task.id <> "#r2") == expected
    end
  end

  describe "secret_values/1" do
    test "returns only the values of keys flagged secret" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true},
          "LOG_LEVEL" => %{"value" => "debug", "secret" => false}
        })

      task = task_in(ws)
      assert WorkerEnv.secret_values(task.id) == ["tok_secret"]
    end

    test "returns [] when no keys are secret" do
      task = task_in(workspace_with_env(%{"LOG_LEVEL" => %{"value" => "debug"}}))
      assert WorkerEnv.secret_values(task.id) == []
    end

    test "returns [] for an unknown / nil task id" do
      assert WorkerEnv.secret_values("does-not-exist") == []
      assert WorkerEnv.secret_values(nil) == []
    end

    # bd-b2t0kw: an antigravity service-account key reaches a worker as a file, never as
    # an env pair, so it is not in `pairs/1`; it must still be scrubbed from the output.
    test "carries the workspace's agy service-account key, though no env pair does" do
      ws = workspace_with_env(%{})
      private_key = "-----BEGIN PRIVATE KEY-----\nMIIEvfake\n-----END PRIVATE KEY-----\n"

      key =
        Jason.encode!(%{
          "type" => "service_account",
          "project_id" => "arb-agy-test",
          "private_key_id" => "abc123def456",
          "private_key" => private_key,
          "client_email" => "arb-agy@arb-agy-test.iam.gserviceaccount.com"
        })

      account =
        Ash.create!(Wardmast.Accounts.ProviderAccount, %{provider: :antigravity, slug: "we-sa"})

      Ash.create!(Wardmast.Accounts.WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :antigravity,
        provider_account_id: account.id
      })

      {:ok, _} =
        Wardmast.Accounts.rotate_credential(account.id, %{
          "kind" => "service_account",
          "secret" => key
        })

      task = task_in(ws)
      values = WorkerEnv.secret_values(task.id)

      assert key in values
      assert private_key in values
      assert "abc123def456" in values
      assert WorkerEnv.pairs(task.id) == []
    end
  end

  describe "resolve/1 observability" do
    test "warns when the workspace resolves but its encrypted store is unreadable despite configured keys" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true}
        })

      task = task_in(ws)

      # Simulate the storage-half degrading independently of the public
      # worker_env_meta half (e.g. a corrupt/cleared ciphertext column) —
      # exactly the "both halves written, only one readable" shape this
      # ticket is about. Direct SQL bypasses Ash's write-only `worker_env`
      # argument, which has no update path for the raw encrypted column.
      Wardmast.Repo.update_all(
        from(w in "workspaces", where: w.id == ^ws.id),
        set: [encrypted_worker_env: nil]
      )

      log =
        capture_log(fn ->
          assert WorkerEnv.resolve(task.id) == {[], []}
        end)

      assert log =~ "WorkerEnv"
      assert log =~ task.id
      assert log =~ ws.id
    end

    test "does not warn for a genuinely unconfigured workspace" do
      task = task_in(workspace_with_env(%{}))

      log =
        capture_log(fn ->
          assert WorkerEnv.resolve(task.id) == {[], []}
        end)

      assert log == ""
    end

    test "warns when the decrypted store is missing some, but not all, configured keys" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true},
          "LOG_LEVEL" => %{"value" => "debug", "secret" => false}
        })

      task = task_in(ws)

      # Simulate a partially-degraded store: the decrypted map is missing
      # LOG_LEVEL even though worker_env_meta still lists it as configured.
      # Direct SQL bypasses Ash's write-only `worker_env` argument, which has
      # no update path for the raw encrypted column.
      partial =
        Wardmast.Vault.encrypt!(:erlang.term_to_binary(%{"API_TOKEN" => "tok_secret"}))
        |> Base.encode64()

      Wardmast.Repo.update_all(
        from(w in "workspaces", where: w.id == ^ws.id),
        set: [encrypted_worker_env: partial]
      )

      log =
        capture_log(fn ->
          assert WorkerEnv.resolve(task.id) == {[{"API_TOKEN", "tok_secret"}], ["tok_secret"]}
        end)

      assert log =~ "WorkerEnv"
      assert log =~ "LOG_LEVEL"
      refute log =~ "API_TOKEN,"
    end

    test "does not warn when the store resolves normally" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true}
        })

      task = task_in(ws)

      log =
        capture_log(fn ->
          assert WorkerEnv.resolve(task.id) == {[{"API_TOKEN", "tok_secret"}], ["tok_secret"]}
        end)

      assert log == ""
    end
  end
end

defmodule Wardmast.Mergers.GitlabCanceledJobsTest do
  @moduledoc "Canceled jobs are inconclusive, never failing checks (bd-189j66)."
  use ExUnit.Case, async: false

  alias Wardmast.Mergers.Gitlab
  alias Wardmast.Mergers.Gitlab.Config

  @ref "!525"
  @env_var "GTE_GITLAB_CANCELED_TEST_TOKEN"
  @pipelines "/api/v4/projects/12345/merge_requests/525/pipelines"

  setup do
    System.put_env(@env_var, "test-gitlab-token")

    Config.put_active(%{
      "host" => "gitlab.com",
      "project_id" => 12_345,
      "credentials_ref" => "env:#{@env_var}",
      "default_target_branch" => "main"
    })

    Gitlab.Budget.reset()

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp json(conn, body), do: conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)

  defp stub_pipeline(status, jobs) do
    Req.Test.stub(Wardmast.Mergers.Gitlab.HTTP, fn conn ->
      cond do
        conn.request_path == @pipelines ->
          json(conn, [%{"id" => 3_092_513_819, "sha" => "2e9e85e1", "status" => status}])

        String.ends_with?(conn.request_path, "/jobs") ->
          json(conn, jobs)

        String.contains?(conn.request_path, "/trace") ->
          conn |> Plug.Conn.put_status(200) |> Plug.Conn.resp(200, "trace")
      end
    end)
  end

  defp job(id, name, status),
    do: %{"id" => id, "name" => name, "status" => status, "web_url" => "https://gl/j/#{id}"}

  @all_canceled for {n, i} <-
                      Enum.with_index(
                        ~w(audit:dialyzer audit:fast coverage visual test-1/4 test-2/4 test-3/4 test-4/4)
                      ),
                    do: %{
                      "id" => i + 1,
                      "name" => n,
                      "status" => "canceled",
                      "web_url" => "https://gl/j/#{i + 1}"
                    }

  test "a pipeline whose every job is canceled yields no failing checks" do
    stub_pipeline("canceled", @all_canceled)
    assert {:ok, []} = Gitlab.failing_check_logs(@ref)
  end

  test "a failed pipeline reports only the failed job, not its canceled siblings" do
    stub_pipeline("failed", [
      job(1, "test 1/4", "failed"),
      job(2, "coverage", "canceled"),
      job(3, "audit:dialyzer", "canceled")
    ])

    assert {:ok, [%{name: "test 1/4", status: "failed"}]} = Gitlab.failing_check_logs(@ref)
  end
end

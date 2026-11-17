defmodule Wardmast.Preview.WorkspaceConfigTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.Tasks.Workspace

  defp create(worker) do
    Ash.create(Workspace, %{
      name: "preview-cfg-#{System.unique_integer([:positive])}",
      config: %{"worker" => worker}
    })
  end

  test "accepts worker.preview and worker.repos.<repo>.preview" do
    assert {:ok, _} =
             create(%{
               "preview" => %{"port_range" => "31000-31999", "idle_ttl_seconds" => 3600},
               "repos" => %{
                 "arbiter" => %{
                   "preview" => %{
                     "command" => "mix phx.server",
                     "setup" => "mix deps.get && mix ecto.setup",
                     "env" => %{"DATABASE_PATH" => "/tmp/preview-{{task_id}}.sqlite3"},
                     "ready_path" => "/",
                     "ready_timeout" => 120
                   }
                 }
               }
             })
  end

  test "refuses unknown and invalid values, naming the full path" do
    assert {:error, %Ash.Error.Invalid{} = err} =
             create(%{"repos" => %{"arbiter" => %{"preview" => %{"comand" => "x"}}}})

    assert Exception.message(err) =~ "worker.repos.arbiter.preview has unknown key(s) comand"

    assert {:error, %Ash.Error.Invalid{} = err} =
             create(%{"preview" => %{"port_range" => "22000-23000"}})

    assert Exception.message(err) =~ "worker.preview.port_range"

    assert {:error, %Ash.Error.Invalid{} = err} =
             create(%{"repos" => %{"arbiter" => %{"preview" => %{"ready_timeout" => "soon"}}}})

    assert Exception.message(err) =~ "worker.repos.arbiter.preview.ready_timeout"
  end
end

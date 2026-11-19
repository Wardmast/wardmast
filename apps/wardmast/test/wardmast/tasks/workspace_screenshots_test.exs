defmodule Wardmast.Tasks.WorkspaceScreenshotsTest do
  use Wardmast.DataCase, async: true

  alias Wardmast.Tasks.Workspace

  defp create(worker),
    do:
      Ash.create(Workspace, %{
        name: "shots-#{System.unique_integer([:positive])}",
        config: %{"worker" => worker}
      })

  @block %{"ui_paths" => ["assets/**"], "start_cmd" => "mix phx.server"}

  test "accepts the block workspace-wide and a partial per-repo override" do
    assert {:ok, ws} =
             create(%{
               "screenshots" => @block,
               "repos" => %{
                 "app" => %{"screenshots" => %{"base_url" => "http://localhost:{{port}}"}}
               }
             })

    assert {:ok, _} = Wardmast.Screenshots.Config.resolve(ws, "app") |> ok_or_flunk()
  end

  test "refuses unknown keys and bad values, naming the path" do
    assert {:error, err} = create(%{"repos" => %{"app" => %{"screenshots" => %{"bogus" => 1}}}})
    assert Exception.message(err) =~ "worker.repos.app.screenshots has unknown key(s) bogus"

    assert {:error, err} =
             create(%{"screenshots" => Map.put(@block, "base_url", "http://evil.com")})

    assert Exception.message(err) =~ "worker.screenshots.base_url"
  end

  defp ok_or_flunk({:ok, _} = ok), do: ok
  defp ok_or_flunk(other), do: flunk("expected {:ok, _}, got #{inspect(other)}")
end

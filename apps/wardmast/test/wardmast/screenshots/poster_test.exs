defmodule Wardmast.Screenshots.PosterTest do
  use ExUnit.Case, async: false

  alias Wardmast.Screenshots.{Poster, Section}

  defmodule FakeForge do
    @moduledoc false
    # Agent-backed forge: the description and what host_images should answer.
    def agent, do: :persistent_term.get({__MODULE__, :agent})

    def host_images(_ref, images, _opts) do
      case Agent.get(agent(), & &1.hosting) do
        :ok ->
          {:ok, Map.new(images, fn i -> {i.name, {:ok, "https://img.test/" <> i.name}} end)}

        {:partial, bad} ->
          {:ok,
           Map.new(images, fn i ->
             if i.name =~ bad,
               do: {i.name, {:error, %{message: "HTTP 413"}}},
               else: {i.name, {:ok, "https://img.test/" <> i.name}}
           end)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def get_description(_ref), do: {:ok, Agent.get(agent(), & &1.description)}

    def update_description(_ref, body) do
      case Agent.get(agent(), & &1.update) do
        :ok ->
          Agent.update(agent(), &%{&1 | description: body})
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule NoHosting do
    @moduledoc false
    def get_description(_ref), do: {:ok, "desc"}
    def update_description(_ref, _body), do: :ok
  end

  setup do
    agent =
      start_supervised!({Agent, fn -> %{description: "Summary", hosting: :ok, update: :ok} end})

    :persistent_term.put({FakeForge, :agent}, agent)
    on_exit(fn -> :persistent_term.erase({FakeForge, :agent}) end)

    test = self()
    {:ok, agent: agent, record: fn reason -> send(test, {:recorded, reason}) end}
  end

  defp pairs(suffix \\ "") do
    [
      %{
        label: "Edit modal" <> suffix,
        before: %{name: "edit-before.png", data: "B"},
        after: %{name: "edit-after.png", data: "A"}
      },
      %{
        label: "Settings",
        before: {:text, "new at this commit"},
        after: %{name: "s.png", data: "S"}
      }
    ]
  end

  defp description(agent), do: Agent.get(agent, & &1.description)

  test "hosts the images and writes the table into the description", %{agent: a, record: rec} do
    assert {:ok, %{rows: 2, failures: []}} = Poster.post(FakeForge, "#1", pairs(), %{record: rec})

    d = description(a)
    assert d =~ "Summary"
    assert d =~ "## Screenshots"

    assert d =~
             "| Edit modal | ![before](https://img.test/0-before-edit-before.png) | ![after](https://img.test/0-after-edit-after.png) |"

    assert d =~ "| Settings | _new at this commit_ | ![after](https://img.test/1-after-s.png) |"
    refute_received {:recorded, _}
  end

  test "a later round replaces the table instead of appending a second", %{agent: a, record: rec} do
    {:ok, _} = Poster.post(FakeForge, "#1", pairs(), %{record: rec})
    {:ok, _} = Poster.post(FakeForge, "#1", pairs(" v2"), %{record: rec})

    d = description(a)
    assert length(String.split(d, Section.start_marker())) == 2
    assert d =~ "Edit modal v2"
    refute d =~ "| Edit modal |"
    assert String.starts_with?(d, "Summary")
  end

  test "a failed upload renders a reason in the table and is recorded", %{agent: a, record: rec} do
    Agent.update(a, &%{&1 | hosting: {:partial, "edit-before"}})

    assert {:ok, %{failures: [%{name: name, reason: reason}]}} =
             Poster.post(FakeForge, "#1", pairs(), %{record: rec})

    assert name =~ "edit-before"
    assert reason =~ "413"
    assert description(a) =~ "| Edit modal | _upload failed: HTTP 413_ | ![after]"
    assert_received {:recorded, recorded}
    assert recorded =~ "413"
  end

  test "a whole-set failure (public repo blocked) renders reasons and is recorded", %{
    agent: a,
    record: rec
  } do
    Agent.update(a, &%{&1 | hosting: {:error, :public_repo_blocked}})

    assert {:ok, %{failures: failures}} = Poster.post(FakeForge, "#1", pairs(), %{record: rec})
    assert length(failures) == 3

    d = description(a)
    assert d =~ "public_repo_blocked"
    refute d =~ "![after]"
    assert_received {:recorded, recorded}
    assert recorded =~ "public_repo_blocked"
  end

  test "an adapter without host_images is a recorded failure, not a skip", %{record: rec} do
    assert {:ok, %{failures: [_ | _]}} = Poster.post(NoHosting, "#1", pairs(), %{record: rec})
    assert_received {:recorded, recorded}
    assert recorded =~ "unsupported"
  end

  test "a description that cannot be written is an error and is recorded", %{
    agent: a,
    record: rec
  } do
    Agent.update(a, &%{&1 | update: {:error, %{message: "HTTP 500"}}})

    assert {:error, reason} = Poster.post(FakeForge, "#1", pairs(), %{record: rec})
    assert inspect(reason) =~ "500"
    assert_received {:recorded, recorded}
    assert recorded =~ "500"
  end

  test "pairs with no image at all still write the table and upload nothing", %{
    agent: a,
    record: rec
  } do
    only_text = [
      %{
        label: "Billing",
        before: {:text, "capture failed: selector"},
        after: {:text, "capture failed: selector"}
      }
    ]

    assert {:ok, %{rows: 1, failures: []}} =
             Poster.post(FakeForge, "#1", only_text, %{record: rec})

    assert description(a) =~ "| Billing | _capture failed: selector_ |"
  end
end

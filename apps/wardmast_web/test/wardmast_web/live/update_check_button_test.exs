defmodule WardmastWeb.UpdateCheckButtonTest do
  @moduledoc "The dashboard's \"Check for updates\" control (shared backend: Status.update_check/0)."
  use WardmastWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Wardmast.Release.UpdateCheck

  defp start_checker(tag) do
    Req.Test.stub(
      UpdateCheck,
      &Req.Test.json(&1, %{"tag_name" => tag, "html_url" => "https://x.test"})
    )

    pid =
      start_supervised!(
        {UpdateCheck,
         enabled: true,
         repo: "acme/arbiter",
         running_version: "0.2.0",
         initial_delay_ms: :infinity,
         req_options: [plug: {Req.Test, UpdateCheck}]}
      )

    Req.Test.allow(UpdateCheck, self(), pid)
    UpdateCheck.check_now()
  end

  test "the button shows Up to date when nothing newer is out", %{conn: conn} do
    start_checker("v0.2.0")
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#update-available")
    assert has_element?(view, "#update-check-button[phx-disable-with]")

    view |> element("#update-check-button") |> render_click()

    refute has_element?(view, "#update-available")
    assert has_element?(view, "#update-check-status", "Up to date")
  end

  test "a newly found update surfaces the banner without a reload", %{conn: conn} do
    start_checker("v0.2.0")
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#update-available")

    Req.Test.stub(
      UpdateCheck,
      &Req.Test.json(&1, %{"tag_name" => "v99.0.0", "html_url" => "https://x.test"})
    )

    view |> element("#update-check-button") |> render_click()

    assert has_element?(view, "#update-available", "v99.0.0")
    assert has_element?(view, "#update-deploy-button")
  end
end

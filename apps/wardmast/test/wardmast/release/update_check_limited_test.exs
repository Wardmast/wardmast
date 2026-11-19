defmodule Wardmast.Release.UpdateCheckLimitedTest do
  use ExUnit.Case, async: true

  alias Wardmast.Release.UpdateCheck

  defp start(name, opts) do
    opts =
      Keyword.merge(
        [
          name: name,
          enabled: true,
          repo: "acme/arbiter",
          running_version: "0.2.0",
          initial_delay_ms: :infinity,
          req_options: [plug: {Req.Test, name}]
        ],
        opts
      )

    pid = start_supervised!({UpdateCheck, opts})
    Req.Test.allow(name, self(), pid)
  end

  test "a second manual check inside the window returns the cached result without a fetch" do
    name = :"uc_lim_#{System.unique_integer([:positive])}"
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(name, fn conn ->
      Agent.update(calls, &(&1 + 1))
      Req.Test.json(conn, %{"tag_name" => "v0.3.0", "html_url" => "u"})
    end)

    start(name, [])

    assert {:fresh, %{latest: "v0.3.0", update_available?: true}} =
             UpdateCheck.check_limited(name)

    assert {:cached, %{latest: "v0.3.0"}} = UpdateCheck.check_limited(name)
    assert Agent.get(calls, & &1) == 1
  end

  test "a manual check runs again once the window has passed" do
    name = :"uc_lim2_#{System.unique_integer([:positive])}"
    Req.Test.stub(name, &Req.Test.json(&1, %{"tag_name" => "v0.3.0"}))
    start(name, manual_interval_ms: 0)

    assert {:fresh, _} = UpdateCheck.check_limited(name)
    assert {:fresh, _} = UpdateCheck.check_limited(name)
  end

  test "reports :disabled when the checker is not running" do
    assert {:disabled, %{enabled: false}} = UpdateCheck.check_limited(:no_such_update_check)
  end
end

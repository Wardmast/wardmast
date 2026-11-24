defmodule WardmastReleaseEnv.TestMaxCasesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # bd-90vo7y: scripts/test_max_cases.exs is shared by all four test helpers.
  @script Path.expand("../../../scripts/test_max_cases.exs", __DIR__)

  setup_all do
    {fun, _} = Code.eval_file(@script)
    %{opts: fun}
  end

  defp worker_default, do: min(4, max(2, div(System.schedulers_online(), 4)))

  test "explicit value wins, in and out of a worker", %{opts: opts} do
    assert opts.(%{"ARB_TEST_MAX_CASES" => "3"}) == [max_cases: 3]

    assert opts.(%{"ARB_TEST_MAX_CASES" => " 5 ", "ARB_WORKER_BEAD_ID" => "bd-x"}) == [
             max_cases: 5
           ]
  end

  test "unset: ExUnit default outside a worker, capped inside one", %{opts: opts} do
    assert opts.(%{}) == []
    assert opts.(%{"ARB_WORKER_BEAD_ID" => ""}) == []
    assert opts.(%{"ARB_WORKER_BEAD_ID" => "bd-x"}) == [max_cases: worker_default()]
  end

  # bd-76727c: hygiene, not the OOM fix (peak is ~flat in max_cases). A worker session
  # never defaults above 4 concurrent cases, whatever the host's core count.
  test "a worker's default is bounded to 2..4", %{opts: opts} do
    assert [max_cases: n] = opts.(%{"ARB_WORKER_BEAD_ID" => "bd-x"})
    assert n in 2..4
  end

  test "bad values warn and fall back", %{opts: opts} do
    for bad <- ["abc", "0", "-2", "1.5", "4x"] do
      warning =
        capture_io(:stderr, fn -> send(self(), {:r, opts.(%{"ARB_TEST_MAX_CASES" => bad})}) end)

      assert warning =~ "ARB_TEST_MAX_CASES"
      assert_received {:r, []}
    end

    capture_io(:stderr, fn ->
      send(self(), {:r, opts.(%{"ARB_TEST_MAX_CASES" => "abc", "ARB_WORKER_BEAD_ID" => "b"})})
    end)

    assert_received {:r, [max_cases: _]}
  end

  test "the running suite honours ARB_TEST_MAX_CASES" do
    expected = System.get_env("ARB_TEST_MAX_CASES")

    if expected && match?({n, ""} when n >= 1, Integer.parse(expected)) do
      assert ExUnit.configuration()[:max_cases] == String.to_integer(expected)
    end
  end
end

defmodule WardmastReleaseEnv.TestExcludeLinuxTest do
  use ExUnit.Case, async: true

  # bd-cblu5p: scripts/test_exclude_linux.exs is shared by the three app test
  # helpers that carry `:linux`-tagged tests (wardmast, wardmast_web,
  # wardmast_cli). It evaluates to a function (env map, os_type) -> the
  # `exclude:` tags to add.
  @script Path.expand("../../../scripts/test_exclude_linux.exs", __DIR__)

  setup_all do
    {fun, _} = Code.eval_file(@script)
    %{excl: fun}
  end

  test "darwin excludes :linux", %{excl: excl} do
    assert excl.(%{}, {:unix, :darwin}) == [:linux]
  end

  test "linux keeps :linux tests", %{excl: excl} do
    assert excl.(%{}, {:unix, :linux}) == []
  end

  test "WARDMAST_TEST_EXCLUDE_LINUX=1 reproduces the macOS subset on any host", %{excl: excl} do
    assert excl.(%{"WARDMAST_TEST_EXCLUDE_LINUX" => "1"}, {:unix, :linux}) == [:linux]
    assert excl.(%{"WARDMAST_TEST_EXCLUDE_LINUX" => "true"}, {:unix, :linux}) == [:linux]
    assert excl.(%{"WARDMAST_TEST_EXCLUDE_LINUX" => "0"}, {:unix, :linux}) == []
    assert excl.(%{"WARDMAST_TEST_EXCLUDE_LINUX" => ""}, {:unix, :linux}) == []
  end

  test "the tag is never added twice", %{excl: excl} do
    assert excl.(%{"WARDMAST_TEST_EXCLUDE_LINUX" => "1"}, {:unix, :darwin}) == [:linux]
  end
end

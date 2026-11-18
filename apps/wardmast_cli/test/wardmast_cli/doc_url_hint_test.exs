defmodule WardmastCli.DocUrlHintTest do
  use ExUnit.Case, async: true

  test "doc_url points at the GitHub tag of the running version" do
    Process.put(:bd2_app_version, "0.6.3")
    url = WardmastCli.Version.doc_url("docs/worker-security.md", "x")
    assert url =~ ~r{^https://github\.com/[^/]+/[^/]+/blob/v0\.6\.3/docs/worker-security\.md#x$}
  end

  test "doc_url falls back to main for a source build" do
    Process.put(:bd2_app_version, "0.0.0")
    assert WardmastCli.Version.doc_url("docs/a.md") =~ "/blob/main/docs/a.md"
  end

  test "operator-proof refusal hint is a URL, not a repo-relative path" do
    Process.put(:bd2_app_version, "0.6.3")
    {:error, %{hint: hint}} = decode_hint()
    assert hint =~ "https://github.com/"
    assert hint =~ "/blob/v0.6.3/docs/worker-security.md"
    refute hint =~ "see docs/"
  end

  defp decode_hint do
    {:error, %{hint: apply(WardmastCli.OperatorSocket, :__hint__, [%{}])}}
  end
end

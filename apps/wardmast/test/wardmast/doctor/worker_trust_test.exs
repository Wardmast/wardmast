defmodule Wardmast.Doctor.WorkerTrustTest do
  use ExUnit.Case, async: true

  alias Wardmast.Doctor.WorkerTrust

  @moduletag :tmp_dir

  defp write_profile(dir, projects) do
    File.write!(Path.join(dir, ".claude.json"), Jason.encode!(%{"projects" => projects}))
  end

  test "trusted repo is not reported", %{tmp_dir: dir} do
    write_profile(dir, %{"/r/a" => %{"hasTrustDialogAccepted" => true}})
    report = WorkerTrust.report(["/r/a"], dir)
    assert report.profile_present
    assert report.untrusted == []
    assert report.checked == 1
  end

  test "untrusted repo is listed, incl. false flag and absent entry", %{tmp_dir: dir} do
    write_profile(dir, %{
      "/r/a" => %{"hasTrustDialogAccepted" => true},
      "/r/b" => %{"hasTrustDialogAccepted" => false}
    })

    report = WorkerTrust.report(["/r/a", "/r/b", "/r/c", "/r/c"], dir)
    assert report.untrusted == ["/r/b", "/r/c"]
    assert report.checked == 3
  end

  test "missing profile marks every repo untrusted", %{tmp_dir: dir} do
    report = WorkerTrust.report(["/r/a"], Path.join(dir, "nope"))
    refute report.profile_present
    assert report.untrusted == ["/r/a"]
  end

  test "unparseable profile is treated as present with no trust", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".claude.json"), "{not json")
    report = WorkerTrust.report(["/r/a"], dir)
    assert report.profile_present
    assert report.untrusted == ["/r/a"]
  end
end

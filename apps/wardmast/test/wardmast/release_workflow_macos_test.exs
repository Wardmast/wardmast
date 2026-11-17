defmodule Wardmast.ReleaseWorkflowMacosTest do
  @moduledoc """
  Structure of the `build-macos` job in `.github/workflows/release.yml`
  (bd-6uq02m): it publishes `arbiter-<tag>-darwin-arm64.tar.gz` + `.sha256`
  from a macOS runner, and the Linux `build` job is left alone.
  """
  use ExUnit.Case, async: true

  @path Path.expand("../../../../.github/workflows/release.yml", __DIR__)

  setup_all do
    raw = File.read!(@path)
    {:ok, wf} = YamlElixir.read_from_string(raw)
    %{raw: raw, jobs: wf["jobs"]}
  end

  defp run_text(job), do: Enum.map_join(job["steps"], "\n", &"#{&1["name"]}\n#{&1["run"]}")

  test "build-macos runs on an Apple Silicon runner after the Linux build", %{jobs: jobs} do
    job = jobs["build-macos"]
    assert job["runs-on"] == "macos-15"
    assert job["needs"] == "build"
    assert job["permissions"] == %{"contents" => "write"}
  end

  test "build-macos builds OTP with the shared script and caches it", %{jobs: jobs} do
    job = jobs["build-macos"]
    text = run_text(job)
    assert text =~ "scripts/build-release-otp.sh"

    cache = Enum.find(job["steps"], &(to_string(&1["uses"]) =~ "actions/cache"))
    assert cache["with"]["key"] =~ "hashFiles('scripts/build-release-otp.sh')"
    assert cache["with"]["key"] =~ "arm64"
    # Distinct from the Linux key so a cached ELF OTP is never restored here.
    refute cache["with"]["key"] ==
             jobs["build"]["steps"]
             |> Enum.find(&(&1["id"] == "otp-cache"))
             |> get_in(["with", "key"])
  end

  test "build-macos packages a hygienic darwin-arm64 tarball with a checksum", %{jobs: jobs} do
    text = run_text(jobs["build-macos"])

    assert text =~ ~s(arbiter-${TAG}-darwin-arm64.tar.gz)
    assert text =~ "COPYFILE_DISABLE=1"
    assert text =~ "shasum -a 256"
    refute text =~ "sha256sum"
    # No systemd unit in a macOS tarball.
    assert text =~ "arbiter-node.service"
    assert text =~ "check-release-macho-libs.sh"
  end

  test "build-macos ad-hoc signs and verifies before packaging, with no glibc guard", %{jobs: jobs} do
    steps = jobs["build-macos"]["steps"]
    names = Enum.map(steps, & &1["name"])
    sign = Enum.find_index(steps, &((&1["run"] || "") =~ "codesign --force -s -"))
    package = Enum.find_index(names, &(&1 == "Package and checksum release"))

    assert sign != nil and sign < package
    assert Enum.at(steps, sign)["run"] =~ "codesign --verify"
    refute run_text(jobs["build-macos"]) =~ "check-release-glibc.sh"
  end

  test "build-macos publishes tarball and checksum to the release", %{jobs: jobs} do
    publish =
      Enum.find(jobs["build-macos"]["steps"], &(to_string(&1["uses"]) =~ "action-gh-release"))

    assert publish["with"]["files"] =~ "${{ env.TARBALL }}.sha256"
    assert publish["with"]["tag_name"] == "${{ needs.build.outputs.tag }}"
  end

  test "build-macos pins a deployment target and forces the Rust NIF build", %{jobs: jobs} do
    env = jobs["build-macos"]["env"]
    assert env["MACOSX_DEPLOYMENT_TARGET"] =~ ~r/^\d+\.\d+$/
    assert env["RUSTLER_PRECOMPILED_FORCE_BUILD_ALL"] == "1"
    assert env["MIX_ENV"] == "prod"
  end

  test "the Linux build job is unchanged", %{jobs: jobs} do
    build = jobs["build"]
    assert build["runs-on"] == "ubuntu-latest"
    assert build["container"] == %{"image" => "redhat/ubi8"}
    text = run_text(build)
    assert text =~ "arbiter-${TAG}-linux.tar.gz"
    refute text =~ "darwin"
    assert jobs["publish-oci"]["needs"] == "build"
  end
end

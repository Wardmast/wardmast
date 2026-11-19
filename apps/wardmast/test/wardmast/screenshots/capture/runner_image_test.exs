defmodule Wardmast.Screenshots.Capture.RunnerImageTest do
  # The arb-capture runner ships in the shared worker base (bd-485ts3, design N1): the Containerfile
  # must carry the runner and its lockfile byte for byte, install from the lockfile without scripts,
  # keep Node off PATH and survive digest pinning.
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture.RunnerImage
  alias Wardmast.Worker.Image

  @priv Path.expand("../../../../priv/capture", __DIR__)
  @digest "sha256:" <> String.duplicate("a", 64)

  defp base, do: Image.base_containerfile(System.otp_release())

  # The bytes the Containerfile writes to `<dir>/<name>`.
  defp baked(name) do
    [_, b64] =
      Regex.run(
        ~r/printf '%s' '([^']*)' \| base64 -d > #{Regex.escape(RunnerImage.dir())}\/#{Regex.escape(name)}/,
        base()
      )

    b64 |> String.replace("\\\n", "") |> Base.decode64!()
  end

  test "the base builds a capture stage from the official Node image and installs from the lockfile" do
    cf = base()

    assert cf =~
             "FROM docker.io/library/node:#{RunnerImage.node_version()}-trixie-slim AS capture"

    assert cf =~ "npm ci --omit=dev --ignore-scripts"
    refute cf =~ "npm install"
  end

  test "the runner and its lockfile are baked in byte for byte" do
    for name <- ~w(runner.mjs package.json package-lock.json) do
      assert baked(name) == File.read!(Path.join(@priv, name)),
             "#{name} drifted from priv/capture"
    end
  end

  test "the final image gets the runner, a private node and ARB_CAPTURE_DIR, with node off PATH" do
    cf = base()
    assert cf =~ "COPY --from=capture /opt/arbiter/capture /opt/arbiter/capture"
    assert cf =~ "COPY --from=capture /usr/local/bin/node /opt/arbiter/capture/bin/node"
    assert cf =~ "ENV ARB_CAPTURE_DIR=/opt/arbiter/capture"

    assert cf =~
             ~s(LABEL arbiter.capture-runner="playwright-core #{RunnerImage.playwright_core_version()}, node #{RunnerImage.node_version()}")

    # A repo's own Node layer owns /usr/local/bin/node; the base must not touch it or PATH.
    refute cf =~ "COPY --from=capture /usr/local/bin/node /usr/local/bin/node"
    refute cf =~ ~r/ENV PATH=(?!\/opt\/arbiter\/cli:\$PATH)/
  end

  test "playwright-core is pinned exactly, with an integrity hash, and has no install scripts" do
    pkg = @priv |> Path.join("package.json") |> File.read!() |> Jason.decode!()
    lock = @priv |> Path.join("package-lock.json") |> File.read!() |> Jason.decode!()

    version = pkg["dependencies"]["playwright-core"]
    assert version =~ ~r/\A\d+\.\d+\.\d+\z/
    assert RunnerImage.playwright_core_version() == version

    entry = lock["packages"]["node_modules/playwright-core"]
    assert entry["version"] == version
    assert entry["integrity"] =~ ~r/\Asha512-/
    refute Map.has_key?(entry, "hasInstallScript")
    refute Map.has_key?(entry, "dependencies")
  end

  test "the base still pins every external FROM, the capture stage included" do
    assert {:ok, pinned, pins} = Image.pin(base(), fn _ref -> {:ok, @digest} end)

    refs = Enum.map(pins, &elem(&1, 0))
    assert "docker.io/library/node:#{RunnerImage.node_version()}-trixie-slim" in refs
    assert pinned =~ "node:#{RunnerImage.node_version()}-trixie-slim@#{@digest} AS capture"
    # The stage's own COPY --from needs no pin: it names a stage defined above.
    assert pinned =~ "COPY --from=capture"
  end
end

defmodule Wardmast.Worker.Image.CliLayerTest do
  # bd-2esasx: the published image's agy layer proves the pinned binary runs.
  use ExUnit.Case, async: true

  alias Wardmast.Worker.CliSet
  alias Wardmast.Worker.CliSetFixture
  alias Wardmast.Worker.Image.Publisher.Pipeline

  @moduletag :tmp_dir

  defp set(ctx, opts), do: CliSetFixture.set!(ctx.tmp_dir, opts)

  test "the agy layer COPYs the binary and fails the build unless `agy --version` is the pin",
       ctx do
    set = set(ctx, agy: "1.5.9")
    agy = CliSet.cli(set, "agy")

    text = Pipeline.cli_layer_containerfile(agy, "base:tag", [])

    assert text =~ "FROM base:tag\n"
    assert text =~ "COPY agy /opt/arbiter/cli/\n"

    assert text =~
             ~s|RUN test "$(HOME=/tmp /opt/arbiter/cli/agy --version)" = "1.5.9"\n|

    # COPY first, then the check that runs what was copied.
    assert :binary.match(text, "COPY") < :binary.match(text, "RUN")
  end

  test "the other CLIs' layers stay a bare COPY (no build-time execution)", ctx do
    set = set(ctx, agy: "1.5.9")

    for name <- ["codex", "claude"] do
      text = Pipeline.cli_layer_containerfile(CliSet.cli(set, name), "base:tag", [])
      refute text =~ "RUN "
      assert text =~ "COPY "
    end
  end

  test "the last layer carries the set's labels, agy's providers included", ctx do
    set = set(ctx, agy: "1.5.9")
    text = Pipeline.cli_layer_containerfile(CliSet.cli(set, "arb"), "x", CliSet.labels(set))

    assert text =~ ~s|LABEL "arbiter.cli-providers"="claude,codex,gemini"|
    assert text =~ ~s|LABEL "arbiter.cli.agy.version"="1.5.9"|
  end

  test "cli_set/1 does not require agy: an install without it still publishes", ctx do
    opts = CliSetFixture.put(ctx.tmp_dir, [])
    assert {:ok, set} = Pipeline.cli_set(opts)
    assert CliSet.cli(set, "agy") == nil
  end
end

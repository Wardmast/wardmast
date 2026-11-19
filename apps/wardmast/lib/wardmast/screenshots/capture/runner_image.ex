defmodule Wardmast.Screenshots.Capture.RunnerImage do
  @moduledoc """
  How the `arb-capture` runner (`priv/capture`: `runner.mjs`, `package.json`, `package-lock.json`)
  ships in the shared worker base image (`Wardmast.Worker.Image.base_containerfile/1`), next to the
  Chromium it drives (bd-6301r0). The chosen packaging for the design's N1 is **in the worker
  image, not a sidecar**: capture already runs where `$ARB_CHROME` is, and a second image would be a
  second thing to pin, publish and keep in step with the first.

  The image gets, under `/opt/arbiter/capture` (`dir/0`, exported to the shooter as
  `ARB_CAPTURE_DIR`):

    * `runner.mjs`, `package.json` and `package-lock.json`, baked into the Containerfile as base64
      (the base builds from an empty context, as `PodScripts.image_install/0` does);
    * `node_modules/playwright-core`, installed by `npm ci --ignore-scripts` from the lockfile, so
      the version **and its integrity hash** are the lockfile's (`playwright-core` 1.65.1, no
      dependencies, no install scripts, no browser download: Chromium is the image's own);
    * `bin/node`, the official Node image's binary at the pinned `node_version/0`, kept off `PATH`
      so a repo's own Node layer (`Image`'s toolchain `node_layer`) is not shadowed or replaced.

  `build_stage/0` is the throwaway Node stage that produces those; `install/0` the lines that copy
  the result into the base. Bump Node or `playwright-core` on purpose: the Containerfile text changes,
  so the base hash changes and the release rebuilds it.
  """

  @dir "/opt/arbiter/capture"
  @node_version "24.22.3"
  @priv Path.expand("../../../../priv/capture", __DIR__)
  @files ~w(runner.mjs package.json package-lock.json)
  for f <- @files, do: @external_resource(Path.join(@priv, f))
  @contents Map.new(@files, &{&1, File.read!(Path.join(@priv, &1))})
  @playwright_core @contents["package.json"]
                   |> Jason.decode!()
                   |> get_in(["dependencies", "playwright-core"])

  @doc "Where the runner lives in the image (`ARB_CAPTURE_DIR`)."
  @spec dir() :: String.t()
  def dir, do: @dir

  @doc "The Node release the image's `bin/node` is, from the official Node image."
  @spec node_version() :: String.t()
  def node_version, do: @node_version

  @doc "The pinned `playwright-core` version (from `priv/capture/package.json`)."
  @spec playwright_core_version() :: String.t()
  def playwright_core_version, do: @playwright_core

  @doc "The Node build stage: the runner installed from its lockfile at `dir/0`."
  @spec build_stage() :: String.t()
  def build_stage do
    writes =
      for {name, text} <- Enum.sort(@contents) do
        "printf '%s' '#{b64(text)}' | base64 -d > #{@dir}/#{name}"
      end

    """
    # arb-capture runner (bd-485ts3): playwright-core from the lockfile, no scripts, no browser download.
    FROM docker.io/library/node:#{@node_version}-trixie-slim AS capture
    RUN mkdir -p #{@dir} \\
     && #{Enum.join(writes, " \\\n && ")} \\
     && cd #{@dir} && npm ci --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error
    """
  end

  @doc "The final-stage lines that bring the runner and Node into the base."
  @spec install() :: String.t()
  def install do
    """
    COPY --from=capture #{@dir} #{@dir}
    COPY --from=capture /usr/local/bin/node #{@dir}/bin/node
    ENV ARB_CAPTURE_DIR=#{@dir}
    LABEL arbiter.capture-runner="playwright-core #{@playwright_core}, node #{@node_version}"
    """
  end

  defp b64(text) do
    text
    |> Base.encode64()
    |> String.graphemes()
    |> Enum.chunk_every(76)
    |> Enum.map_join("\\\n", &Enum.join/1)
  end
end

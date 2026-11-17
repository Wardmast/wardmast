defmodule WardmastCli.Cmd.SelfUpdate do
  @moduledoc """
  `ward self-update [--version vX.Y.Z] [--json] [--force]`
  — refresh the local `ward` CLI escript from a **GitHub Release**.

  Downloads the `ward` escript asset published by `.github/workflows/release.yml`,
  verifies its SHA-256 checksum, backs up the existing binary, atomically swaps
  in the new `ward` binary, and ensures the `wm` symlink and the one-release
  `arb` deprecation shim sit beside it.

  This is the production CLI-update path: the machine no longer needs a source
  checkout or a Mix/Elixir toolchain to stay current. It mirrors
  `ward server deploy` — download a released artifact, verify, swap — so CLI
  and server self-maintain the same way.

  ## What it does

    1. **Resolve the target release.** Query the GitHub Releases API for
       `latest` (or the tag named by `--version`). The `owner/repo` comes from
       `ARB_RELEASE_REPO`; a `GITHUB_TOKEN`, if set, authenticates the request.
    2. **No-op if already current.** Compare the running escript's version
       against the release tag. Skips the download unless `--force` is passed.
    3. **Download the asset + checksum.** Fetch the `ward` escript asset and its
       `ward.sha256` sidecar from the release (falling back to `arb` /
       `arb.sha256` when deploying a pre-rename release tag).
    4. **Verify sha256.** Recompute the download's SHA-256 and compare to the
       published checksum. A mismatch aborts before anything touches disk state.
    5. **Atomic swap + links.** Back up the existing binary to `<install_path>.bak`,
       write the new binary to a temp file, `chmod +x`, then rename it over the
       existing path (rename(2) is atomic on POSIX). Alongside `ward`, create
       the `wm` symlink (`wm -> ward`) and the `arb` deprecation shim.

  ## Configuration

    * `ARB_RELEASE_REPO` — `owner/repo` to pull releases from (required).
    * `GITHUB_TOKEN` — optional; authenticates the Releases API request.
    * `WARDMAST_INSTALL_BIN` (or `ARB_INSTALL_BIN`) — install path (default `~/.local/bin/ward`).
    * `ARB_GITHUB_API` — Releases API base (default `https://api.github.com`).

  ## Exit codes

    * `0` — the CLI was updated (or was already on the target version).
    * `1` — a precondition failed (missing config, API/download error, checksum
      mismatch, write failure).
  """

  alias WardmastCli.{ArgParser, Output, ReleaseRepo}

  @default_github_api "https://api.github.com"
  @switches [version: :string, json: :boolean, force: :boolean]

  @doc "Entry point for `arb self-update` (and its `arb upgrade` alias)."
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_self_update(argv)
    end
  end

  defp do_self_update(argv) do
    {opts, _rest, mode} = ArgParser.parse(argv, command: "ward self-update", strict: @switches)
    force = opts[:force] || false

    try do
      repo = release_repo()
      release = fetch_release(repo, opts[:version])
      tag = release_tag(release)

      case install(release, repo, tag, force) do
        {:already_current, _} -> emit_already_current(mode, tag)
        {:updated, prior} -> emit_updated(mode, tag, prior)
      end
    catch
      {:self_update_failed, msg, nil} -> Output.die(msg)
      {:self_update_failed, msg, hint} -> Output.die(msg, hint)
    end
  end

  @doc """
  Install the `arb` escript from an already-fetched release (`repo`/`tag`) —
  the half of `arb self-update` that `arb server deploy` runs after a green
  deploy so the CLI matches the server it just put live.

  Never halts the VM: a failure comes back as `{:error, message}` because the
  caller's own work (a healthy server deploy) is already done. Quiet on stdout
  so a `--json` deploy stays one object.
  """
  @spec install_from_release(String.t(), map(), String.t()) ::
          {:ok, %{updated: boolean(), version: String.t(), previous_version: String.t() | nil}}
          | {:error, String.t()}
  def install_from_release(repo, release, tag) do
    Process.put(:arb_self_update_quiet, true)

    try do
      case install(release, repo, tag, true) do
        {:updated, prior} ->
          {:ok,
           %{updated: true, version: tag, previous_version: prior, install_path: install_path()}}

        {:already_current, _} ->
          {:ok, %{updated: false, version: tag, previous_version: nil}}
      end
    catch
      {:self_update_failed, msg, _hint} -> {:error, msg}
    after
      Process.delete(:arb_self_update_quiet)
    end
  end

  defp install(release, repo, tag, force) do
    # Strip the leading `v` from the tag before comparing with the app version
    # (the app version is stored without the prefix, e.g. "0.1.10").
    tag_version = String.trim_leading(tag, "v")
    current_version = WardmastCli.Version.app_version()

    if not force and tag_version == current_version do
      {:already_current, current_version}
    else
      {ward_url, sha_url} = cli_assets(release, tag)

      log("Downloading ward escript from #{repo}@#{tag}…")
      ward_bytes = download_binary(ward_url)
      expected_sha = parse_sha256(download_binary(sha_url))

      verify_sha256!(ward_bytes, expected_sha)
      log("Checksum verified (sha256 #{String.slice(expected_sha, 0, 12)}…).")

      atomic_swap!(install_path(), ward_bytes)
      {:updated, current_version}
    end
  end

  # Every failure inside the install path throws, so `arb self-update` can turn
  # it into a halt and `install_from_release/3` into an `{:error, _}`.
  @spec fail(String.t()) :: no_return()
  @spec fail(String.t(), String.t() | nil) :: no_return()
  defp fail(msg, hint \\ nil), do: throw({:self_update_failed, msg, hint})

  # ---- release resolution --------------------------------------------------

  defp release_repo do
    case ReleaseRepo.resolve() do
      {:ok, repo, source} ->
        IO.puts(:stderr, "Release source: #{repo} (#{ReleaseRepo.describe(source)}).")
        repo

      :error ->
        fail(
          "could not determine which GitHub repo publishes Wardmast releases",
          "Set ARB_RELEASE_REPO=owner/repo, or use a release-built arb (it carries its own repo)."
        )
    end
  end

  defp fetch_release(repo, nil), do: github_get!(repo, "releases/latest", "latest")
  defp fetch_release(repo, tag), do: github_get!(repo, "releases/tags/#{tag}", tag)

  defp github_get!(repo, path, what) do
    url = github_api() <> "/repos/" <> repo <> "/" <> path

    req_opts =
      [
        method: :get,
        url: url,
        headers: github_headers(),
        receive_timeout: 30_000,
        retry: false
      ] ++ test_opts()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body

      {:ok, %Req.Response{status: 404}} ->
        fail(
          "no #{what} release found in #{repo}",
          "Check `--version` matches a published tag, or publish a release first."
        )

      {:ok, %Req.Response{status: status}} ->
        fail("GitHub Releases API returned HTTP #{status} for #{url}")

      {:error, reason} ->
        fail(
          "could not reach the GitHub Releases API",
          "Requesting #{url} failed: #{inspect(reason)}"
        )
    end
  end

  defp release_tag(%{"tag_name" => tag}) when is_binary(tag) and tag != "", do: tag

  defp release_tag(_),
    do: fail("release metadata has no tag_name", "The Releases API response was malformed.")

  # Locate the `ward` escript asset and its `ward.sha256` sidecar (falling back
  # to `arb` / `arb.sha256` for pre-rename release tags).
  defp cli_assets(%{"assets" => assets}, tag) when is_list(assets) do
    case asset_url(assets, "ward") do
      url when is_binary(url) ->
        require_sha_url(assets, url, "ward.sha256", tag)

      nil ->
        case asset_url(assets, "arb") do
          url when is_binary(url) ->
            require_sha_url(assets, url, "arb.sha256", tag)

          nil ->
            fail(
              "release #{tag} has no asset named `ward`",
              "The release workflow should publish it; re-run the build if it's missing."
            )
        end
    end
  end

  defp cli_assets(_, tag), do: fail("release #{tag} has no assets")

  defp require_sha_url(assets, bin_url, sha_name, tag) do
    case asset_url(assets, sha_name) do
      sha_url when is_binary(sha_url) ->
        {bin_url, sha_url}

      nil ->
        fail(
          "release #{tag} has no checksum asset named `#{sha_name}`",
          "Refusing to update without a checksum to verify the download against."
        )
    end
  end

  defp asset_url(assets, name) do
    Enum.find_value(assets, fn
      %{"name" => ^name, "browser_download_url" => url} when is_binary(url) -> url
      _ -> nil
    end)
  end

  # ---- download + verify ---------------------------------------------------

  defp download_binary(url) do
    req_opts =
      [
        method: :get,
        url: url,
        headers: github_headers(),
        decode_body: false,
        raw: true,
        receive_timeout: 120_000,
        retry: false
      ] ++ test_opts()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body

      {:ok, %Req.Response{status: status}} ->
        fail("download failed: HTTP #{status} for #{url}")

      {:error, reason} ->
        fail("download failed for #{url}", inspect(reason))
    end
  end

  defp parse_sha256(contents) do
    contents
    |> to_string()
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> case do
      hex when is_binary(hex) and hex != "" -> String.downcase(hex)
      _ -> fail("could not parse the published sha256 checksum")
    end
  end

  defp verify_sha256!(bytes, expected) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    unless actual == expected do
      fail(
        "sha256 checksum mismatch — refusing to update",
        "expected #{expected}\n             got #{actual}\n" <>
          "The download is corrupt or tampered with. Aborting before touching the binary."
      )
    end
  end

  # ---- atomic swap ---------------------------------------------------------

  defp atomic_swap!(install_path, bytes) do
    install_dir = Path.dirname(install_path)

    case File.mkdir_p(install_dir) do
      :ok -> :ok
      {:error, reason} -> fail("could not create #{install_dir}: #{inspect(reason)}")
    end

    backup_existing!(install_path, install_dir)

    # Write to a temp file alongside the target, then rename(2) over it.
    tmp = install_path <> ".new"
    _ = File.rm(tmp)

    with :ok <- File.write(tmp, bytes),
         :ok <- File.chmod(tmp, 0o755),
         :ok <- File.rename(tmp, install_path),
         :ok <- install_links(install_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        fail("failed to install ward to #{install_path}", inspect(reason))
    end
  end

  defp backup_existing!(install_path, install_dir) do
    # Back up the existing binary so the user can roll back manually. When
    # crossing the `arb` -> `ward` rename on a host that only has `arb` so far,
    # back up that `arb` binary before the shim replaces it.
    source =
      cond do
        File.exists?(install_path) -> install_path
        File.regular?(Path.join(install_dir, "arb")) -> Path.join(install_dir, "arb")
        true -> nil
      end

    if source do
      bak = install_path <> ".bak"

      case File.copy(source, bak) do
        {:ok, _} -> log("Backed up existing binary to #{bak}")
        {:error, reason} -> fail("could not back up #{source}: #{inspect(reason)}")
      end
    end
  end

  @doc """
  Create the `wm` symlink (`wm -> <target>`) and the one-release `arb`
  deprecation shim alongside `install_path`.
  """
  @spec install_links(String.t()) :: :ok | {:error, term()}
  def install_links(install_path) do
    install_dir = Path.dirname(install_path)
    target_name = Path.basename(install_path)
    wm_path = Path.join(install_dir, "wm")
    wm_tmp = wm_path <> ".new"
    arb_path = Path.join(install_dir, "arb")
    arb_tmp = arb_path <> ".new"

    _ = File.rm(wm_tmp)
    _ = File.rm(arb_tmp)

    with :ok <- File.ln_s(target_name, wm_tmp),
         :ok <- File.rename(wm_tmp, wm_path),
         :ok <- File.write(arb_tmp, arb_shim(target_name)),
         :ok <- File.chmod(arb_tmp, 0o755),
         :ok <- place_arb_shim(arb_tmp, arb_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(wm_tmp)
        _ = File.rm(arb_tmp)
        {:error, reason}
    end
  end

  # An escript lazily loads modules from its own file, so renaming the shim over
  # the `arb` file that is currently running makes the next module load read
  # shell text and abort the VM. When the target is the running script, leave
  # the staged `.new` file and record it; `flush_pending_shim/0` renames it in
  # once the caller has finished (report printed, status written).
  defp place_arb_shim(arb_tmp, arb_path) do
    if running_script?(arb_path) do
      Process.put(:arb_pending_shim, {arb_tmp, arb_path})
      :ok
    else
      File.rename(arb_tmp, arb_path)
    end
  end

  defp running_script?(path) do
    running =
      Process.get(:arb_running_script_override) ||
        try do
          to_string(:escript.script_name())
        catch
          _, _ -> nil
        end

    is_binary(running) and same_file?(Path.expand(running), Path.expand(path))
  end

  defp same_file?(a, b), do: a == b or real_path(a) == real_path(b)

  defp real_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} -> Path.expand(to_string(target), Path.dirname(path))
      _ -> path
    end
  end

  @doc """
  Rename a deferred `arb` shim into place (see `install_links/1`). Call it as the
  last thing a command does, after its output is written. No-op when nothing
  was deferred.
  """
  @spec flush_pending_shim() :: :ok | {:error, term()}
  def flush_pending_shim do
    case Process.delete(:arb_pending_shim) do
      {tmp, dest} ->
        case File.rename(tmp, dest) do
          :ok ->
            :ok

          {:error, _} = err ->
            _ = File.rm(tmp)
            err
        end

      nil ->
        :ok
    end
  end

  @doc """
  The one-release `arb` deprecation shim installed alongside `ward`: prints a
  one-line deprecation notice to stderr and `exec`s `ward` with the caller's
  `argv`.
  """
  @spec arb_shim(String.t()) :: String.t()
  def arb_shim(target_name \\ "ward") do
    """
    #!/bin/sh
    echo 'arb: note: `arb` is deprecated; use `ward` (or `wm`) instead.' >&2
    dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
    if [ -n "$dir" ] && [ -x "$dir/#{target_name}" ]; then
      exec "$dir/#{target_name}" "$@"
    fi
    exec #{target_name} "$@"
    """
  end

  # ---- paths / config ------------------------------------------------------

  @doc "Where the `ward` escript is installed (`WARDMAST_INSTALL_BIN` / `ARB_INSTALL_BIN`, default `~/.local/bin/ward`)."
  @spec install_path() :: String.t()
  def install_path do
    case Wardmast.Env.get("WARDMAST_INSTALL_BIN") do
      path when is_binary(path) and path != "" ->
        normalize_install_path(Path.expand(path))

      _ ->
        Path.join(System.user_home!(), ".local/bin/ward")
    end
  end

  defp normalize_install_path(path) do
    if Path.basename(path) == "arb" do
      Path.join(Path.dirname(path), "ward")
    else
      path
    end
  end

  defp github_api do
    case System.get_env("ARB_GITHUB_API") do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @default_github_api
    end
  end

  defp github_headers do
    base = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer #{token}"} | base]

      _ ->
        base
    end
  end

  defp test_opts, do: Process.get(:bd2_req_options, [])

  defp log(msg) do
    cond do
      Process.get(:bd2_req_options) -> :ok
      Process.get(:arb_self_update_quiet) -> IO.puts(:stderr, msg)
      true -> IO.puts(msg)
    end
  end

  # ---- output --------------------------------------------------------------

  defp emit_already_current(:json, tag) do
    IO.puts(
      Jason.encode!(%{
        version: tag,
        updated: false,
        already_current: true,
        ok: true
      })
    )
  end

  defp emit_already_current(:text, tag) do
    IO.puts("Already on #{tag} — nothing to update.")
    IO.puts("(Pass --force to reinstall the same version, or --version to pick another.)")
  end

  defp emit_updated(:json, tag, prior_version) do
    install = install_path()

    IO.puts(
      Jason.encode!(%{
        version: tag,
        previous_version: prior_version,
        updated: true,
        already_current: false,
        install_path: install,
        ok: true
      })
    )
  end

  defp emit_updated(:text, tag, prior_version) do
    install = install_path()
    IO.puts("")

    IO.puts(
      "Updated ward to #{tag}" <> if(prior_version, do: " (was #{prior_version})", else: "")
    )

    IO.puts("Installed at #{install}")
    IO.puts("")
    IO.puts("Run `ward version` to confirm the new version is active.")
  end
end

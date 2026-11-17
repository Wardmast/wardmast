defmodule WardmastCli.Cmd.InstallCli do
  @moduledoc """
  `arb install-cli [--json]` — rebuild and install the CLI escript.

  Builds the CLI from `apps/wardmast_cli` and installs it to `~/.local/bin/arb`,
  making it executable. Useful when CLI code changes locally and you want the
  updated escript on your PATH without waiting for a full deploy.

  What it does:

    1. **Locate the checkout** — same root resolution as `arb start`/`arb restart`.
    2. **Build the escript** via `mix escript.build` from `apps/wardmast_cli`.
    3. **Install to `~/.local/bin/arb`** and make it executable.

  ## Exit codes

    * `0` — escript built and installed successfully.
    * `1` — build or install failed, or project root could not be located.
  """

  alias WardmastCli.{ArgParser, Cmd.SelfUpdate, Cmd.Start, Output}

  @switches [json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _mode} =
        ArgParser.parse(argv, command: "arb install cli", switches: @switches)

      mode = if opts[:json], do: :json, else: :text

      root =
        case Start.project_root() do
          {:ok, dir} ->
            dir

          :error ->
            Output.die(
              "could not locate the Wardmast project root (no compose.yml found)",
              "Set ARB_HOME to your Wardmast checkout, or run `arb install-cli` from inside it."
            )
        end

      case build_and_install_cli(root) do
        :ok ->
          emit_success(mode, root)

        {:error, msg} ->
          Output.die("install-cli failed", msg)
      end
    end
  end

  defp build_and_install_cli(root) do
    cli_dir = Path.join(root, "apps/wardmast_cli")

    if File.dir?(cli_dir) do
      build_escript(cli_dir)
    else
      {:error,
       "CLI source directory not found: #{cli_dir}\n" <>
         "  hint: resolved root (#{root}) is not an Wardmast checkout — " <>
         "set ARB_HOME to your checkout or run `arb install-cli` from inside it"}
    end
  end

  # Pre-existing complexity 10 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp build_escript(cli_dir) do
    Start.log_text("Building CLI escript (mix escript.build)…")

    case Start.run_cmd("mix", ["escript.build"], cd: cli_dir, stderr_to_stdout: true) do
      {_out, 0} ->
        escript_path = Path.join(cli_dir, "ward")
        install_path = SelfUpdate.install_path()

        # Ensure ~/.local/bin exists
        install_dir = Path.dirname(install_path)

        case File.mkdir_p(install_dir) do
          :ok ->
            # Copy the escript to ~/.local/bin/ward
            case File.copy(escript_path, install_path) do
              {:ok, _} ->
                # Make it executable
                # Pre-existing nesting 4 — baselined when bd-4x2yhq first
                # wired Credo up. Thresholds stay at the tool's own default so new
                # code is held to it; see the note in .credo.exs.
                # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                with :ok <- File.chmod(install_path, 0o755),
                     :ok <- SelfUpdate.install_links(install_path) do
                  Start.log_text("Installed CLI escript to #{install_path}")
                  :ok
                else
                  {:error, reason} ->
                    {:error, "Could not finalize escript install: #{inspect(reason)}"}
                end

              {:error, reason} ->
                {:error, "Could not copy escript to #{install_path}: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, "Could not create directory #{install_dir}: #{inspect(reason)}"}
        end

      {out, code} ->
        {:error, "Build failed (exit #{code}): #{String.trim_trailing(out)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "Could not run mix: #{inspect(e.original)}"}
  end

  defp emit_success(:json, _root) do
    install_path = SelfUpdate.install_path()

    IO.puts(
      Jason.encode!(%{
        status: "ok",
        message: "CLI escript built and installed",
        install_path: install_path
      })
    )
  end

  defp emit_success(:text, _root) do
    install_path = SelfUpdate.install_path()

    IO.puts("")
    IO.puts("CLI escript built and installed at #{install_path}")
    IO.puts("Run `ward help` to verify the new version is on your PATH.")
  end
end

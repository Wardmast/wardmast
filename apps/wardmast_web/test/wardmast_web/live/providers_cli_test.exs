defmodule WardmastWeb.ProvidersCliTest do
  @moduledoc """
  bd-5wfsj7: the Providers page lists each provider CLI the server detected (path,
  version, minimum supported version) and, for a missing or outdated one, the
  vendor's install/upgrade command as copyable text. Stub binaries only; nothing
  on the page runs an installer.
  """
  use WardmastWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Wardmast.Agents.CliDetection

  @moduletag :linux
  @async_timeout WardmastWeb.Test.Timing.scale(5_000)

  setup do
    dir = Path.join(System.tmp_dir!(), "pc#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prior = Application.get_env(:wardmast, CliDetection)

    Application.put_env(:wardmast, CliDetection,
      enforce: false,
      probe: true,
      path: dir,
      min_versions: %{"claude" => "2.0.0", "codex" => "0.100.0"}
    )

    on_exit(fn ->
      Application.put_env(:wardmast, CliDetection, prior)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp stub(dir, name, version) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\necho '#{version}'\n")
    File.chmod!(path, 0o755)
    path
  end

  defp live_providers(conn) do
    {:ok, view, _html} = live(conn, ~p"/providers")
    {:ok, view, render_async(view, @async_timeout)}
  end

  test "shows installed path and version for a current CLI, with no install step", %{
    conn: conn,
    dir: dir
  } do
    path = stub(dir, "claude", "2.3.4")
    {:ok, view, _} = live_providers(conn)

    assert has_element?(view, "#cli-claude[data-status=ok]")
    assert has_element?(view, "#cli-claude-version", "2.3.4")
    assert has_element?(view, "#cli-claude-path", path)
    refute has_element?(view, "#cli-claude-command")
  end

  test "a missing CLI offers the documented install command, copyable", %{conn: conn} do
    {:ok, view, _} = live_providers(conn)

    assert has_element?(view, "#cli-codex[data-status=missing]")
    assert has_element?(view, "#cli-codex-command", "npm install -g @openai/codex")
    assert has_element?(view, "#cli-codex-copy[data-copy-value='npm install -g @openai/codex']")
    assert has_element?(view, "#cli-codex-action", "Install")
  end

  test "an outdated CLI is flagged with the required version and an upgrade command", %{
    conn: conn,
    dir: dir
  } do
    stub(dir, "codex", "0.1.0")
    {:ok, view, _} = live_providers(conn)

    assert has_element?(view, "#cli-codex[data-status=outdated]")
    assert has_element?(view, "#cli-codex-detail", "0.100.0")
    assert has_element?(view, "#cli-codex-action", "Upgrade")
    assert has_element?(view, "#cli-codex-command", "@openai/codex@latest")
  end

  test "the page offers no control that runs an installer", %{conn: conn} do
    {:ok, view, _} = live_providers(conn)
    refute has_element?(view, "#provider-clis button[phx-click]")
    refute has_element?(view, "#provider-clis form")
  end
end

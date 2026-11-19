defmodule WardmastCli.Cmd.Doctor.ProviderClisTest do
  @moduledoc "bd-5wfsj7: `ward server doctor` reports each provider CLI the server detected."
  use WardmastCli.CliCase, async: true

  alias WardmastCli.Cmd.Doctor.{Checks, ProviderClis}

  defp cli(provider, status, extra \\ %{}) do
    Map.merge(
      %{
        "provider" => provider,
        "label" => provider,
        "status" => status,
        "path" => nil,
        "version" => nil,
        "min_version" => "2.0.0",
        "action" => nil,
        "install_command" => "npm install -g #{provider}",
        "upgrade_command" => "#{provider} update",
        "detail" => "#{provider} detail"
      },
      extra
    )
  end

  defp by_id(results, id), do: Enum.find(results, &(&1.id == id))

  describe "ProviderClis.checks/2" do
    test "an installed, current CLI is ok and names path and version" do
      [row] =
        ProviderClis.checks(
          [cli("claude", "ok", %{"path" => "/opt/bin/claude", "version" => "2.3.4"})],
          nil
        )

      assert row.id == "provider_cli_claude"
      assert row.group == :auth
      assert row.status == :ok
      assert row.detail =~ "2.3.4"
      assert row.detail =~ "/opt/bin/claude"
    end

    test "a missing CLI warns with the install command and does not block readiness" do
      [row] = ProviderClis.checks([cli("codex", "missing", %{"action" => "install"})], nil)

      assert row.status == :warn
      assert row.hint =~ "npm install -g codex"
      refute row.blocks_readiness
    end

    test "an outdated CLI fails, naming the installed and the required version" do
      [row] =
        ProviderClis.checks(
          [
            cli("claude", "outdated", %{
              "path" => "/p/claude",
              "version" => "1.0.9",
              "action" => "upgrade"
            })
          ],
          nil
        )

      assert row.status == :fail
      assert row.detail =~ "1.0.9"
      assert row.detail =~ "2.0.0"
      assert row.hint =~ "claude update"
      refute row.blocks_readiness
    end

    test "an unreadable version warns" do
      [row] = ProviderClis.checks([cli("codex", "unknown_version", %{"path" => "/p/codex"})], nil)
      assert row.status == :warn
    end

    test "a login-shell PATH is reported; an old server (no clis) adds nothing" do
      rows =
        ProviderClis.checks([], %{
          "source" => "login_shell",
          "shell" => "/bin/zsh",
          "added" => ["/opt/homebrew/bin"]
        })

      assert [%{id: "server_path", status: :ok, detail: detail}] = rows
      assert detail =~ "/bin/zsh"
      assert detail =~ "/opt/homebrew/bin"

      assert ProviderClis.checks(nil, nil) == []
    end

    test "a login shell that failed is a warning" do
      [row] =
        ProviderClis.checks([], %{
          "source" => "inherited",
          "reason" => "{:resolve_failed, :timeout}"
        })

      assert row.status == :warn
      assert row.detail =~ "timeout"
    end
  end

  describe "Checks.run/1 reads the CLIs from the server's /api/server/platform" do
    test "each provider CLI shows up as a check" do
      stub_routes([
        {{"get", "/api/server/platform"},
         {%{
            "os" => "linux",
            "path" => "/usr/bin",
            "tools" => %{},
            "clis" => [
              cli("claude", "ok", %{"path" => "/p/claude", "version" => "2.3.4"}),
              cli("codex", "missing", %{"action" => "install"}),
              cli("antigravity", "outdated", %{"version" => "1.0.0", "path" => "/p/agy"})
            ],
            "path_source" => %{"source" => "inherited", "reason" => "path_not_minimal"}
          }, 200}}
      ])

      results = Checks.run(spawn: :skip)

      assert by_id(results, "provider_cli_claude").status == :ok
      assert by_id(results, "provider_cli_codex").status == :warn
      assert by_id(results, "provider_cli_antigravity").status == :fail
      refute by_id(results, "server_path")
    end

    test "a server without the field adds no provider CLI checks" do
      stub_routes([
        {{"get", "/api/server/platform"},
         {%{"os" => "linux", "path" => "/usr/bin", "tools" => %{}}, 200}}
      ])

      refute by_id(Checks.run(spawn: :skip), "provider_cli_claude")
    end
  end
end

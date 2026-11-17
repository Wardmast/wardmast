defmodule WardmastCli.Cmd.Doctor.DarwinTest do
  use WardmastCli.CliCase, async: true

  alias WardmastCli.Cmd.Doctor.{Checks, Darwin}

  @darwin {:unix, :darwin}
  @brew_path "/opt/homebrew/bin:/usr/local/bin:/usr/bin"
  @tools ~w(gtimeout claude gh glab mise)

  defp all_present, do: Map.new(@tools, &{&1, "/opt/homebrew/bin/" <> &1})
  defp none_present, do: Map.new(@tools, &{&1, nil})
  defp darwin_opts, do: [path: @brew_path, tools: all_present()]

  defp by_id(results, id), do: Enum.find(results, &(&1.id == id))

  describe "Darwin.checks/1" do
    test "all tools on the server's PATH are ok" do
      results = Darwin.checks(darwin_opts())

      for id <-
            ~w(darwin_gtimeout darwin_homebrew_path darwin_claude darwin_gh darwin_glab darwin_mise) do
        assert %{status: :ok} = by_id(results, id)
      end
    end

    test "tmux is left to the server-side tmux check" do
      refute by_id(Darwin.checks(darwin_opts()), "darwin_tmux")
    end

    test "missing tools are reported, claude as a fail that does not block readiness" do
      results = Darwin.checks(path: "/usr/bin", tools: none_present())

      assert by_id(results, "darwin_gtimeout").status == :warn
      assert by_id(results, "darwin_homebrew_path").status == :warn
      assert by_id(results, "darwin_mise").status == :warn
      claude = by_id(results, "darwin_claude")
      assert claude.status == :fail
      refute claude.blocks_readiness
      assert claude.hint =~ "brew"
    end

    test "states write confinement and egress as unconfined" do
      results = Darwin.checks(darwin_opts())

      write = by_id(results, "darwin_write_confinement")
      assert write.status == :warn
      assert write.detail =~ "permission_layer"
      assert write.detail =~ "unconfined"

      egress = by_id(results, "darwin_egress")
      assert egress.status == :warn
      assert egress.detail =~ "none"
      assert egress.detail =~ "unconfined"
    end
  end

  describe "Checks.run(os: darwin)" do
    test "Linux-only checks report n/a, not fail" do
      stub_routes([])
      results = Checks.run(os: @darwin, spawn: :skip, darwin: darwin_opts())

      for id <- ~w(agy_write_jail agy_jail_escape agy_jail_reads agy_jail_network
                   agy_jail_keyring agy_ssh_transport egress_jail podman_sandbox
                   worker_memory worker_jail_unmask) do
        r = by_id(results, id)
        assert r.status == :na, "#{id} should be n/a, got #{inspect(r)}"
        assert r.detail =~ "macOS"
      end
    end

    test "darwin checks are included, in the sandboxes group" do
      stub_routes([])
      results = Checks.run(os: @darwin, spawn: :skip, darwin: darwin_opts())
      assert %{group: :sandboxes} = by_id(results, "darwin_write_confinement")
    end

    test "on linux no darwin checks appear" do
      stub_routes([])
      results = Checks.run(os: {:unix, :linux}, spawn: :skip)
      refute by_id(results, "darwin_gtimeout")
    end
  end

  describe "Checks.run/1 takes the platform and PATH from the server" do
    test "a darwin server: PATH and tool lookups come from /api/server/platform" do
      stub_routes([
        {{"get", "/api/server/platform"},
         {%{
            "os" => "darwin",
            "path" => "/usr/bin",
            "tools" => Map.put(none_present(), "gh", "/usr/bin/gh")
          }, 200}}
      ])

      results = Checks.run(spawn: :skip)

      assert by_id(results, "darwin_homebrew_path").status == :warn
      assert by_id(results, "darwin_claude").status == :fail
      assert by_id(results, "darwin_gh").status == :ok
      assert by_id(results, "worker_memory").status == :na
    end

    test "a linux server is not treated as darwin whatever the CLI host is" do
      stub_routes([
        {{"get", "/api/server/platform"},
         {%{"os" => "linux", "path" => "/usr/bin", "tools" => %{}}, 200}}
      ])

      results = Checks.run(spawn: :skip)

      refute by_id(results, "darwin_claude")
      refute by_id(results, "worker_memory") && by_id(results, "worker_memory").status == :na
    end

    test "an older server without the endpoint is treated as non-darwin" do
      stub_routes([])
      refute by_id(Checks.run(spawn: :skip), "darwin_claude")
    end
  end
end

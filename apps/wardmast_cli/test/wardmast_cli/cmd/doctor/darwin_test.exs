defmodule WardmastCli.Cmd.Doctor.DarwinTest do
  use WardmastCli.CliCase, async: true

  alias WardmastCli.Cmd.Doctor.{Checks, Darwin}

  @darwin {:unix, :darwin}
  @brew_path "/opt/homebrew/bin:/usr/local/bin:/usr/bin"

  defp all_present(name, _path), do: "/opt/homebrew/bin/" <> name
  defp none_present(_name, _path), do: nil

  defp by_id(results, id), do: Enum.find(results, &(&1.id == id))

  describe "Darwin.checks/1" do
    test "all tools on the captured PATH are ok" do
      results = Darwin.checks(path: @brew_path, find: &all_present/2)

      for id <-
            ~w(darwin_tmux darwin_gtimeout darwin_homebrew_path darwin_claude darwin_gh darwin_glab darwin_mise) do
        assert %{status: :ok} = by_id(results, id)
      end
    end

    test "missing tools are reported, claude as a fail that does not block readiness" do
      results = Darwin.checks(path: "/usr/bin", find: &none_present/2)

      assert by_id(results, "darwin_tmux").status == :warn
      assert by_id(results, "darwin_gtimeout").status == :warn
      assert by_id(results, "darwin_homebrew_path").status == :warn
      assert by_id(results, "darwin_mise").status == :warn
      claude = by_id(results, "darwin_claude")
      assert claude.status == :fail
      refute claude.blocks_readiness
      assert claude.hint =~ "brew"
    end

    test "the finder is given the captured PATH, not the ambient one" do
      test_pid = self()

      find = fn name, path ->
        send(test_pid, {:find, name, path})
        nil
      end

      Darwin.checks(path: "/captured/bin", find: find)
      assert_received {:find, "gtimeout", "/captured/bin"}
    end

    test "states write confinement and egress as unconfined" do
      results = Darwin.checks(path: @brew_path, find: &all_present/2)

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

      results =
        Checks.run(os: @darwin, spawn: :skip, darwin: [path: @brew_path, find: &all_present/2])

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

      results =
        Checks.run(os: @darwin, spawn: :skip, darwin: [path: @brew_path, find: &all_present/2])

      assert %{group: :sandboxes} = by_id(results, "darwin_write_confinement")
    end

    test "on linux no darwin checks appear" do
      stub_routes([])
      results = Checks.run(os: {:unix, :linux}, spawn: :skip)
      refute by_id(results, "darwin_tmux")
    end
  end
end

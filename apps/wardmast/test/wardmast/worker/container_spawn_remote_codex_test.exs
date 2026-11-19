defmodule Wardmast.Worker.ContainerSpawnRemoteCodexTest do
  @moduledoc """
  SI8 (`docs/design/remote-workers.md` §21.3.3, §21.9): the primary's half of a Codex run
  placed on a machine node. `prepare_remote/1` seeds the *mirror* (`<run tmp>/codex-home`)
  with `Codex.ConfigDir.seed_run_home/2`, exactly where a local run keeps its copy, and
  `remote_spec/3` carries the mirror's generated files (never the operator's history) as the
  spec's `secret_files` against a `"tmpfs": true` `config_dir`. The login must appear nowhere
  but there: not in the spec's env or secrets, not in a log.

  Placement does not send Codex to a node yet (no node advertises
  `caps.credential_sync` until the carry-back lands): the last test pins that.
  """
  use Wardmast.DataCase, async: false

  import ExUnit.CaptureLog

  alias Wardmast.Agents.SecurityPolicy
  alias Wardmast.NodeAgent.RunSpec
  alias Wardmast.Nodes.Placement
  alias Wardmast.Test.GitFixture
  alias Wardmast.Worker.CliSetFixture
  alias Wardmast.Worker.ContainerSpawn
  alias Wardmast.Worker.PrivateClone

  @branch "feature/bd-si8-codex"
  @image "localhost/arb-test/codex:1"
  @refresh "rt-SI8-PRIMARY-5c2e"

  defp auth(refresh) do
    Jason.encode!(%{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "id_token" => "id",
        "access_token" => "access-" <> refresh,
        "refresh_token" => refresh,
        "account_id" => "acct"
      },
      "last_refresh" => "2026-10-01T00:00:00Z"
    })
  end

  defp podman_policy do
    SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})
  end

  defp put_env!(key, value) do
    previous = Application.fetch_env(:wardmast, key)
    Application.put_env(:wardmast, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:wardmast, key, v)
        :error -> Application.delete_env(:wardmast, key)
      end
    end)
  end

  setup do
    ctx = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    {:ok, clone} = PrivateClone.create(ctx.checkout, @branch, "main")

    dir = Path.join(ctx.root, "scratch")
    File.mkdir_p!(dir)
    proxy = Path.join(dir, "proxy.sock")
    bridge = Path.join(dir, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")

    # The operator's codex home: the login, a config with a personal profile, and history
    # that no remote run may be sent.
    source_home = Path.join(dir, "operator-codex")
    File.mkdir_p!(source_home)
    File.write!(Path.join(source_home, "auth.json"), auth(@refresh))
    File.write!(Path.join(source_home, "config.toml"), ~s(model = "personal"\n))
    File.write!(Path.join(source_home, "state_5.sqlite"), "HISTORY-MUST-STAY")

    cli_opts = CliSetFixture.put(Path.join(dir, "cli"))
    tmp_dir = Path.join(dir, "run-tmp")
    File.mkdir_p!(tmp_dir)

    put_env!(:worker_container_available, true)
    put_env!(:worker_container_network_available, true)
    put_env!(:worker_container_image, nil)

    test_pid = self()

    egress = fn opts ->
      send(test_pid, {:egress, opts})
      {:ok, [proxy_socket: proxy, proxy_port: 41_001, bridges: [{41_002, bridge}]], "rtest"}
    end

    ref = "registry.example.com/arb/beam@sha256:" <> String.duplicate("b", 64)
    node = %{id: Ecto.UUID.generate(), kind: "machine", caps: %{"image" => "registry"}}

    opts =
      [
        provider: "codex",
        policy: podman_policy(),
        worktree_path: clone,
        owner: self(),
        task_id: "bd-si8test",
        arb_token: "arb-secret-token",
        tmp_dir: tmp_dir,
        image: @image,
        podman: "/usr/bin/podman",
        codex_source_home: source_home,
        egress: egress,
        node: node,
        publish: [stub: fn _ -> {:ok, %{ref: ref}} end]
      ] ++ cli_opts

    Map.merge(ctx, %{clone: clone, source_home: source_home, tmp_dir: tmp_dir, opts: opts})
  end

  defp wire_spec!(ctx, request) do
    port_args = %{
      argv: [ContainerSpawn.provider_path("codex"), "exec", "the prompt"],
      cd: ctx.clone,
      env: ContainerSpawn.apply_env([], request)
    }

    {:ok, spec} = ContainerSpawn.remote_spec(request, port_args, "run-si8-1")
    spec |> Jason.encode!() |> Jason.decode!()
  end

  test "prepare_remote/1 seeds the mirror where a local run keeps its copy", ctx do
    assert {:ok, request} = ContainerSpawn.prepare_remote(ctx.opts)

    assert request.provider == "codex"
    assert request.config_dir == Path.join(ctx.tmp_dir, "codex-home")
    assert File.read!(Path.join(request.config_dir, "auth.json")) == auth(@refresh)
    assert File.read!(Path.join(request.config_dir, "AGENTS.md")) =~ "arb done"
    assert File.exists?(Path.join(request.config_dir, "config.toml"))
    assert File.exists?(Path.join(request.config_dir, "rules/arbiter.rules"))
    # the operator's history is not part of a run's home
    refute File.exists?(Path.join(request.config_dir, "state_5.sqlite"))
    # nothing is mounted as a file seed: the files are secret_files
    assert request.config_files == %{}
  end

  test "the mirror's four files ride secret_files, linked at allowlisted paths", ctx do
    {:ok, request} = ContainerSpawn.prepare_remote(ctx.opts)
    wire = wire_spec!(ctx, request)

    links = for {_name, %{"link" => link}} <- wire["secret_files"], do: link
    assert Enum.sort(links) == ["AGENTS.md", "auth.json", "config.toml", "rules/arbiter.rules"]

    by_link =
      Map.new(wire["secret_files"], fn {_n, f} -> {f["link"], Base.decode64!(f["content"])} end)

    assert by_link["auth.json"] == File.read!(Path.join(request.config_dir, "auth.json"))
    assert by_link["config.toml"] == File.read!(Path.join(request.config_dir, "config.toml"))
    assert by_link["AGENTS.md"] == File.read!(Path.join(request.config_dir, "AGENTS.md"))

    assert by_link["rules/arbiter.rules"] ==
             File.read!(Path.join(request.config_dir, "rules/arbiter.rules"))

    # a spec the agent will accept
    assert {:ok, %RunSpec{secret_files: files}} = RunSpec.validate(wire)
    assert map_size(files) == 4
  end

  test "the config_dir mount says tmpfs, at the primary's own path, with no file seed", ctx do
    {:ok, request} = ContainerSpawn.prepare_remote(ctx.opts)
    wire = wire_spec!(ctx, request)

    mount = Enum.find(wire["mounts"], &(&1["kind"] == "config_dir"))
    assert mount["tmpfs"] == true
    assert mount["path"] == request.config_dir
    assert mount["files"] == %{}
    # like CLAUDE_CONFIG_DIR, the config-dir variable rides the run's env file
    assert Map.merge(wire["env"], wire["secrets"])["CODEX_HOME"] == request.config_dir
  end

  test "the login is in secret_files and nowhere else of the spec", ctx do
    {:ok, request} = ContainerSpawn.prepare_remote(ctx.opts)
    wire = wire_spec!(ctx, request)

    outside = wire |> Map.delete("secret_files") |> Jason.encode!()
    refute outside =~ @refresh
    refute outside =~ Base.encode64(auth(@refresh))
    refute Map.values(wire["secrets"]) |> Enum.join() =~ @refresh
    refute Jason.encode!(wire["env"]) =~ @refresh
    assert Jason.encode!(wire["secret_files"]) =~ Base.encode64(auth(@refresh))
  end

  test "preparing and building the spec logs no secret_files content", ctx do
    log =
      capture_log([level: :debug], fn ->
        {:ok, request} = ContainerSpawn.prepare_remote(ctx.opts)
        wire = wire_spec!(ctx, request)
        {:ok, _} = RunSpec.validate(wire)
        _ = inspect(RunSpec.redact(wire))
      end)

    refute log =~ @refresh
    refute log =~ Base.encode64(auth(@refresh))
  end

  test "the spec's redacted form names the files and none of their bytes", ctx do
    {:ok, request} = ContainerSpawn.prepare_remote(ctx.opts)
    wire = wire_spec!(ctx, request)
    redacted = inspect(RunSpec.redact(wire), limit: :infinity, printable_limit: :infinity)

    refute redacted =~ @refresh
    refute redacted =~ Base.encode64(auth(@refresh))
    assert redacted =~ "[redacted]"
  end

  test "a Claude spec is unchanged: no secret_files, no tmpfs", ctx do
    opts = Keyword.put(ctx.opts, :provider, "claude")
    {:ok, request} = ContainerSpawn.prepare_remote(opts)

    port_args = %{argv: ["claude", "--print"], cd: ctx.clone, env: []}
    {:ok, spec} = ContainerSpawn.remote_spec(request, port_args, "run-si8-claude")

    refute Map.has_key?(spec, "secret_files")
    mount = Enum.find(spec["mounts"], &(&1["kind"] == "config_dir"))
    refute Map.has_key?(mount, "tmpfs")
  end

  test "a source with no login still places: an empty mirror, no auth.json to carry", ctx do
    File.rm!(Path.join(ctx.source_home, "auth.json"))
    {:ok, request} = ContainerSpawn.prepare_remote(ctx.opts)
    wire = wire_spec!(ctx, request)

    links = for {_name, %{"link" => link}} <- wire["secret_files"], do: link
    refute "auth.json" in links
    assert "config.toml" in links
  end

  test "placement still keeps Codex off a machine node: nothing advertises credential_sync" do
    node = %{
      id: "n1",
      kind: :machine,
      caps: %{"image" => "registry"},
      status: :online
    }

    refute Placement.credential_synced?(node, "codex")
    refute Placement.credential_synced?(node, :codex)
    assert Placement.credential_synced?(node, "claude")
  end
end

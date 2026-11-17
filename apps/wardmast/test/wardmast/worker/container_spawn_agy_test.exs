defmodule Wardmast.Worker.ContainerSpawnAgyTest do
  @moduledoc """
  bd-b2t0kw: agy (provider `gemini`) under `sandbox.backend: podman`.

  Host-side and argv-level, like `ContainerSpawnCodexTest`: `ContainerSpawn.prepare/1`
  and `wrap_port/1` with `provider: "gemini"` against a real private clone, a stand-in
  egress run and a stand-in `podman`. What an agy container needs that Claude's does not:
  its own `$HOME` seeded with the generated `settings.json` (`Gemini.Security`), the
  worker `GEMINI.md` and the run's MCP config, and the workspace's Google Cloud
  service-account key as a `podman run --secret` that `GOOGLE_APPLICATION_CREDENTIALS`
  names, with `AGY_ADC_AUTH=true`. No keyring, no operator `$HOME`, and no value of the
  key on argv, in the request or in a log.
  """
  use Wardmast.DataCase, async: false

  import ExUnit.CaptureLog

  alias Wardmast.Accounts
  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Accounts.WorkspaceProviderAccount
  alias Wardmast.Agents.Gemini.ConfigDir
  alias Wardmast.Agents.SecurityPolicy
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.GitFixture
  alias Wardmast.Worker.CliSetFixture
  alias Wardmast.Worker.Container
  alias Wardmast.Worker.ContainerSpawn
  alias Wardmast.Worker.PrivateClone
  alias Wardmast.Worker.Sandbox

  @branch "feature/bd-agy-podman"
  @image "localhost/arb-test/agy:1"
  @private_key "-----BEGIN PRIVATE KEY-----\nMIIEvAGYPODMANfake\n-----END PRIVATE KEY-----\n"

  defp key_json do
    Jason.encode!(%{
      "type" => "service_account",
      "project_id" => "arb-agy-podman",
      "private_key_id" => "c0ffeec0ffeec0ffee",
      "private_key" => @private_key,
      "client_email" => "arb-agy@arb-agy-podman.iam.gserviceaccount.com"
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

  defp workspace!(with_key?) do
    ws = Ash.create!(Workspace, %{name: "agy-podman-#{System.unique_integer([:positive])}"})

    account =
      Ash.create!(ProviderAccount, %{
        provider: :antigravity,
        slug: "agy-podman-#{System.unique_integer([:positive])}"
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :antigravity,
      provider_account_id: account.id
    })

    if with_key? do
      {:ok, _} =
        Accounts.rotate_credential(account.id, %{
          "kind" => "service_account",
          "secret" => key_json()
        })
    end

    ws
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

    # The operator's HOME, which an agy container must never see (no passthrough).
    operator_home = Path.join(dir, "operator-home")
    File.mkdir_p!(Path.join(operator_home, ".ssh"))
    File.write!(Path.join([operator_home, ".ssh", "id_ed25519"]), "OPERATOR-SSH-KEY")

    cli_opts = CliSetFixture.put(Path.join(dir, "cli"), agy: "1.5.9")
    agy = CliSetFixture.host_path(cli_opts, "agy", "agy")

    tmp_dir = Path.join(dir, "run-tmp")
    File.mkdir_p!(tmp_dir)

    put_env!(:worker_container_available, true)
    put_env!(:worker_container_network_available, true)
    put_env!(:worker_container_image, nil)
    put_env!(:worker_isolate_config, true)
    put_env!(:worker_agy_home_root, Path.join(dir, "agy-homes"))
    put_env!(:worker_agy_source_home, operator_home)

    test_pid = self()

    put_env!(:worker_container_runner, fn cmd, args, _opts ->
      case args do
        ["secret", "create", name, file] ->
          send(test_pid, {:secret_created, name, File.read!(file)})

        ["secret", "rm", "--ignore", name] ->
          send(test_pid, {:secret_removed, name})

        _ ->
          send(test_pid, {:ran, cmd, args})
      end

      {"", 0}
    end)

    egress = fn opts ->
      send(test_pid, {:egress, opts})
      {:ok, [proxy_socket: proxy, proxy_port: 41_001, bridges: [{41_002, bridge}]], "rtest"}
    end

    # What dispatch writes before the spawn (`maybe_write_mcp_config/3`): the run's MCP
    # config in the host's per-worktree agy HOME, bearer and all.
    mcp = %{
      "mcpServers" => %{
        "arbiter" => %{
          "serverUrl" => "http://127.0.0.1:41002/mcp",
          "headers" => %{"Authorization" => "Bearer mcp-scope-token"}
        }
      }
    }

    {:ok, _} = ConfigDir.write_mcp_config(mcp, worktree: clone, security: podman_policy())

    opts =
      [
        provider: "gemini",
        policy: podman_policy(),
        worktree_path: clone,
        owner: self(),
        task_id: "bd-agytest",
        arb_token: "arb-secret-token",
        tmp_dir: tmp_dir,
        image: @image,
        podman: "/usr/bin/podman",
        egress: egress
      ] ++ cli_opts

    Map.merge(ctx, %{clone: clone, dir: dir, agy: agy, tmp_dir: tmp_dir, opts: opts, mcp: mcp})
  end

  defp port_args(ctx, request) do
    %{
      exec: "/bin/sh",
      argv: [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        ContainerSpawn.provider_path("gemini"),
        "-p",
        "the prompt"
      ],
      cd: ctx.clone,
      env: ContainerSpawn.apply_env([], request),
      sandbox: request
    }
  end

  defp env_value(argv, name) do
    Enum.find_value(Enum.chunk_every(argv, 2, 1), fn
      ["-e", ^name <> "=" <> value] -> value
      _ -> nil
    end)
  end

  test "Sandbox.module/2 gives agy the container wrap point under podman" do
    for provider <- [:gemini, "gemini", :antigravity, "antigravity"] do
      assert Sandbox.module(:podman, provider) == {:ok, Container}
    end

    assert ContainerSpawn.provider_path("gemini") == "/opt/arbiter/cli/agy"
  end

  test "prepare/1 seeds the run's own agy HOME: settings, GEMINI.md, MCP config; no operator HOME",
       ctx do
    ws = workspace!(true)
    assert {:ok, request} = ContainerSpawn.prepare([workspace: ws] ++ ctx.opts)

    assert request.provider == "gemini"
    assert request.home == Path.join(ctx.tmp_dir, "home")
    # agy's config root is its HOME (there is no config-dir variable).
    assert request.config_dir == request.home

    settings = Path.join([request.home, ".gemini", "antigravity-cli", "settings.json"])
    assert {:ok, %{} = _posture} = settings |> File.read!() |> Jason.decode()
    assert File.regular?(Path.join([request.home, ".gemini", "GEMINI.md"]))

    mcp_path = Path.join([request.home, ".gemini", "config", "mcp_config.json"])
    assert Jason.decode!(File.read!(mcp_path)) == ctx.mcp
    assert {:ok, %File.Stat{mode: mode}} = File.stat(mcp_path)
    assert Bitwise.band(mode, 0o077) == 0

    # Nothing of the operator's HOME: no `.ssh` link, no passthrough at all.
    refute File.exists?(Path.join(request.home, ".ssh"))
    assert request.home |> File.ls!() |> Enum.sort() == [".gemini"]

    # agy's CLI from the pinned cache, read-only, at its container path.
    assert {ctx.agy, "/opt/arbiter/cli/agy"} in request.cli_mounts
  end

  test "the service-account key is a podman --secret; only its path and the ADC switch are env",
       ctx do
    ws = workspace!(true)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, request} = ContainerSpawn.prepare([workspace: ws] ++ ctx.opts)
        send(self(), {:request, request})
      end)

    assert_received {:request, request}
    secret = request.name <> "-agy-adc"
    key = key_json()
    assert_received {:secret_created, ^secret, ^key}

    assert %{name: ^secret, type: :mount, target: "agy-adc.json", uid: uid} =
             Enum.find(request.git_secrets, &(&1.name == secret))

    assert is_integer(uid)
    refute Enum.any?(request.git_secrets, &Map.has_key?(&1, :value))

    assert {"AGY_ADC_AUTH", "true"} in request.env
    assert {"GOOGLE_APPLICATION_CREDENTIALS", "/run/secrets/agy-adc.json"} in request.env

    assert {:ok, wrapped} = ContainerSpawn.wrap_port(port_args(ctx, request))
    argv = wrapped.argv

    assert Enum.any?(
             argv,
             &(&1 == "#{secret},type=mount,target=agy-adc.json,uid=#{uid},mode=0400")
           )

    # Like every spawn pair, these reach the container as `-e NAME` from the client's env.
    for {name, value} <- [
          {"AGY_ADC_AUTH", "true"},
          {"GOOGLE_APPLICATION_CREDENTIALS", "/run/secrets/agy-adc.json"}
        ] do
      assert ["-e", name] in Enum.chunk_every(argv, 2, 1)
      assert {name, value} in wrapped.env
    end

    assert env_value(argv, "HOME") == request.home
    assert "/opt/arbiter/cli/agy" in argv

    # The key is nowhere but the podman secret store.
    for haystack <- [inspect(request), inspect(argv), inspect(wrapped.env), log] do
      refute haystack =~ "PRIVATE KEY"
      refute haystack =~ "MIIEvAGYPODMANfake"
    end

    # Teardown takes the secret with the container.
    :ok = ContainerSpawn.teardown(wrapped)
    assert_received {:secret_removed, ^secret}
  end

  test "agy's egress baseline is the Google hosts an ADC run reaches", ctx do
    ws = workspace!(true)
    assert {:ok, _request} = ContainerSpawn.prepare([workspace: ws] ++ ctx.opts)
    assert_received {:egress, egress_opts}

    for host <-
          ~w(oauth2.googleapis.com:443 www.googleapis.com:443 aiplatform.googleapis.com:443 play.googleapis.com:443) do
      assert host in egress_opts[:infra]
    end
  end

  test "a workspace whose antigravity account holds no key is refused, with what to do", ctx do
    ws = workspace!(false)

    assert {:error, {:agy_credential_missing, message}} =
             ContainerSpawn.prepare([workspace: ws] ++ ctx.opts)

    assert message =~ "arb account rotate"
    assert message =~ "--kind service_account"
    refute_received {:secret_created, _, _}
  end

  # The cluster pod (`docs/design/remote-workers.md` K§12): the key and the MCP config
  # ride the run spec's `secret_files`, through the controller's memory and `/boot`, to
  # the pod's memory volume. Never the pod spec, never its env, never a log.
  describe "a run placed on a cluster node" do
    alias Wardmast.NodeAgent.K8s.PodSpec
    alias Wardmast.NodeAgent.PodChannel.BootBundle
    alias Wardmast.NodeAgent.RunSpec
    alias Wardmast.Test.K8sPodFixtures, as: Fx

    defp remote_request!(ctx, ws) do
      ref = "#{Fx.registry()}/beam@sha256:#{Fx.digest()}"

      node = %{
        id: Ecto.UUID.generate(),
        kind: "cluster",
        caps: %{"image" => "registry", "agy" => true}
      }

      opts =
        [workspace: ws, node: node, publish: [stub: fn _ -> {:ok, %{ref: ref}} end]] ++ ctx.opts

      {:ok, request} = ContainerSpawn.prepare_remote(opts)
      request
    end

    defp wire_spec!(request) do
      port_args = %{
        argv: [ContainerSpawn.provider_path("gemini"), "-p", "the prompt"],
        env: ContainerSpawn.apply_env([], request)
      }

      {:ok, spec} = ContainerSpawn.remote_spec(request, port_args, "run-agy-1")
      spec |> Jason.encode!() |> Jason.decode!()
    end

    test "prepare_remote/1 gives agy its HOME's config dir and generated config files", ctx do
      request = remote_request!(ctx, workspace!(true))

      assert request.provider == "gemini"
      assert request.config_dir == Path.join(request.home, ".gemini")

      assert request.config_files |> Map.keys() |> Enum.sort() ==
               ["GEMINI.md", "antigravity-cli/settings.json"]

      assert {:ok, %{}} = Jason.decode(request.config_files["antigravity-cli/settings.json"])
    end

    test "the key and the MCP config ride secret_files only; spec env names the key's pod path",
         ctx do
      wire = wire_spec!(remote_request!(ctx, workspace!(true)))

      assert %{"agy-adc.json" => %{"content" => key64}} = wire["secret_files"]
      assert Base.decode64!(key64) == key_json()

      assert %{"content" => mcp64, "link" => "config/mcp_config.json"} =
               wire["secret_files"]["agy-mcp.json"]

      assert Jason.decode!(Base.decode64!(mcp64)) == ctx.mcp

      env = Map.merge(wire["env"], wire["secrets"])
      assert env["AGY_ADC_AUTH"] == "true"
      assert env["GOOGLE_APPLICATION_CREDENTIALS"] == "/run/arb/creds/agy-adc.json"

      config_dir = Enum.find(wire["mounts"], &(&1["kind"] == "config_dir"))
      assert config_dir["path"] =~ ~r{/home/\.gemini$}

      outside = wire |> Map.delete("secret_files") |> Jason.encode!()
      refute outside =~ "PRIVATE KEY"
      refute outside =~ "MIIEvAGYPODMANfake"
      refute outside =~ key64
      refute outside =~ "mcp-scope-token"
    end

    test "the pod spec holds neither; the boot bundle carries both, 0600, and the link", ctx do
      wire = wire_spec!(remote_request!(ctx, workspace!(true)))

      assert {:ok, spec} = RunSpec.validate(wire)
      refute inspect(spec) =~ "PRIVATE KEY"

      assert {:ok, pod} = PodSpec.build(spec, Fx.config(%{install_id: spec.install}))
      pod_json = Jason.encode!(pod)
      refute pod_json =~ "PRIVATE KEY"
      refute pod_json =~ "MIIEvAGYPODMANfake"
      refute pod_json =~ "mcp-scope-token"

      {:ok, files} = :erl_tar.extract({:binary, BootBundle.build(spec, %{})}, [:memory])
      files = Map.new(files, fn {name, body} -> {to_string(name), body} end)

      assert files["secret_files/agy-adc.json"] == key_json()
      assert files["secret_links"] == "agy-mcp.json config/mcp_config.json\n"
      assert files["config_dir/GEMINI.md"] =~ "arb done"
      refute files["manifest.json"] =~ "PRIVATE KEY"
    end

    test "a workspace with no key is refused before anything is published", ctx do
      ws = workspace!(false)
      node = %{id: Ecto.UUID.generate(), kind: "cluster", caps: %{"image" => "registry"}}
      test = self()

      stub = fn _ ->
        send(test, :published)
        {:ok, %{ref: "x"}}
      end

      assert {:error, {:agy_credential_missing, _}} =
               ContainerSpawn.prepare_remote(
                 [workspace: ws, node: node, publish: [stub: stub]] ++ ctx.opts
               )

      refute_received :published
      refute_received {:egress, _}
    end
  end

  test "the git secrets reaper also removes an agy key whose container is gone" do
    test_pid = self()

    runner = fn _cmd, args, _opts ->
      case args do
        ["secret", "ls" | _] ->
          {"arb-bd-x-1234abcd-agy-adc\narb-bd-y-5678abcd-agy-adc\n", 0}

        ["ps" | _] ->
          {"arb-bd-y-5678abcd\n", 0}

        ["secret", "rm", "--ignore", name] ->
          send(test_pid, {:reaped, name})
          {"", 0}
      end
    end

    assert Container.reap_git_secrets(runner: runner, podman: "/usr/bin/podman") ==
             ["arb-bd-x-1234abcd-agy-adc"]

    assert_received {:reaped, "arb-bd-x-1234abcd-agy-adc"}
    refute_received {:reaped, "arb-bd-y-5678abcd-agy-adc"}
  end
end

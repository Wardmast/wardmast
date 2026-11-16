defmodule WardmastProFake.Agent do
  @moduledoc false
  # An agent adapter shipped from outside the `Wardmast.*` namespace, standing in
  # for a package such as a Pro build.
  @behaviour Wardmast.Agents.Agent

  @impl true
  def default_argv(_prompt, _opts), do: ["acme-agent"]
  @impl true
  def spawn_env(_opts), do: []
  @impl true
  def init_session(_opts), do: %{}
  @impl true
  def parse_line(state, _line), do: {state, []}
  @impl true
  def done_sentinel, do: ~r/^done$/
  @impl true
  def usage_attrs(_state), do: %{}
  @impl true
  def provider, do: "acme"
end

defmodule WardmastProFake.RoutingPolicy do
  @moduledoc false
  @behaviour Wardmast.Agents.Routing.Policy

  @impl true
  def choose(_task, _workspace, _ledger), do: %{type: :acme, config: %{"model" => "acme-1"}}
end

defmodule WardmastProFake.QuotaGate do
  @moduledoc false
  @behaviour Wardmast.Quota.Gate

  @impl true
  def check(_task, _quota, _workspace, _opts), do: :allow

  @impl true
  def board_hold(_quota, _policy, _opts), do: :ok
end

defmodule WardmastProFake.AcmeQuota do
  @moduledoc false
  # A provider's own quota table row, as a package outside `Wardmast.*` would
  # persist it.
  defstruct [:used, :captured_at]
end

defmodule WardmastProFake.AcmeQuotaSource do
  @moduledoc false
  @behaviour Wardmast.Quota.Gate.Snapshot.Source

  @impl true
  def normalize(%WardmastProFake.AcmeQuota{} = q, _opts) do
    %Wardmast.Quota.Gate.Snapshot{
      provider: "acme",
      utilization: q.used,
      captured_at: q.captured_at,
      window_label: "day"
    }
  end
end

defmodule WardmastProFake.Extension do
  @moduledoc false
  @behaviour Wardmast.Extension

  @impl true
  def contributions do
    [
      {:agent, "acme", WardmastProFake.Agent},
      {:routing_policy, "acme_fixed", WardmastProFake.RoutingPolicy},
      {:quota_gate, "acme_budget", WardmastProFake.QuotaGate},
      {:quota_snapshot, Atom.to_string(WardmastProFake.AcmeQuota), WardmastProFake.AcmeQuotaSource}
    ]
  end
end

defmodule WardmastProFake.ShadowingExtension do
  @moduledoc false
  @behaviour Wardmast.Extension

  @impl true
  def contributions, do: [{:agent, "claude", WardmastProFake.Agent}]
end

defmodule WardmastProFake.IncompleteExtension do
  @moduledoc false
  @behaviour Wardmast.Extension

  # `Wardmast.Agents.Routing.Policy` has no `choose/3` here.
  @impl true
  def contributions, do: [{:routing_policy, "broken", WardmastProFake.Agent}]
end

defmodule WardmastProFake.UnknownSeamExtension do
  @moduledoc false
  @behaviour Wardmast.Extension

  @impl true
  def contributions, do: [{:no_such_seam, "x", WardmastProFake.Agent}]
end

defmodule WardmastProFake.ToolExtension do
  @moduledoc false
  @behaviour Wardmast.Extension

  @impl true
  def contributions, do: []
  @impl true
  def mcp_tools do
    [
      %{
        name: "acme_tool",
        description: "Acme",
        input_schema: %{"type" => "object", "properties" => %{}},
        tiers: [:coordinator],
        handler: fn _scope, args -> {:ok, %{"echo" => args}} end
      }
    ]
  end
end

defmodule WardmastProFake.ShadowToolExtension do
  @moduledoc false
  @behaviour Wardmast.Extension

  @impl true
  def contributions, do: []
  @impl true
  def mcp_tools do
    [tool] = WardmastProFake.ToolExtension.mcp_tools()
    [%{tool | name: "ticket_show"}]
  end
end

defmodule WardmastProFake.BadToolExtension do
  @moduledoc false
  @behaviour Wardmast.Extension

  @impl true
  def contributions, do: []
  @impl true
  def mcp_tools, do: [%{name: "x"}]
end

defmodule Wardmast.ExtensionsTest do
  # The registry is one install-global `:persistent_term`; tests that swap it
  # must not overlap each other or any async reader.
  use Wardmast.DataCase, async: false

  alias Wardmast.Agents
  alias Wardmast.Agents.Routing
  alias Wardmast.Extensions
  alias Wardmast.Mergers
  alias Wardmast.Quota
  alias Wardmast.Quota.Gate.Snapshot
  alias Wardmast.Sessions.Provider
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Trackers

  setup do
    on_exit(fn -> Extensions.load!() end)
    :ok
  end

  defp ws(config), do: %Workspace{config: config}

  describe "core registration" do
    test "core's in-tree adapters arrive through the same contributions path" do
      assert Wardmast.Extensions.Core in Extensions.loaded()

      assert {:ok, Wardmast.Agents.Claude} = Extensions.fetch(:agent, "claude")
      assert {:ok, Wardmast.Trackers.GitHub} = Extensions.fetch(:tracker, "github")
      assert {:ok, Wardmast.Mergers.Direct} = Extensions.fetch(:merger, "direct")
      assert {:ok, Wardmast.Agents.Routing.Static} = Extensions.fetch(:routing_policy, "static")
      assert {:ok, Wardmast.Quota.Gate.Throttle} = Extensions.fetch(:quota_gate, "throttle")
      assert {:ok, Wardmast.Sessions.Provider.Agy} = Extensions.fetch(:session_provider, "agy")

      assert {:ok, Wardmast.MCP.AgentConfig.Codex} =
               Extensions.fetch(:mcp_agent_config, "codex")

      assert {:ok, Snapshot.Anthropic} =
               Extensions.fetch(:quota_snapshot, Wardmast.Quota.AnthropicQuota)

      assert {:ok, Snapshot.Codex} = Extensions.fetch(:quota_snapshot, Wardmast.Quota.CodexQuota)
      assert {:ok, Snapshot.Google} = Extensions.fetch(:quota_snapshot, Wardmast.Quota.GoogleQuota)
    end

    test "in-tree quota rows still project through the registry" do
      anthropic = %Wardmast.Quota.AnthropicQuota{
        provider: "claude",
        utilization_5h: 0.4,
        status_5h: "allowed",
        utilization_7d: 0.1
      }

      assert %Snapshot{utilization: 0.4, window_label: "5h", secondary_window_label: "7d"} =
               Snapshot.normalize(anthropic)

      assert %Snapshot{utilization: 0.5, window_label: "used"} =
               Snapshot.normalize(%Wardmast.Quota.GoogleQuota{
                 provider: "gemini",
                 used_percent: 50
               })

      assert %Snapshot{status: "limit_reached", utilization: 0.9} =
               Snapshot.normalize(%Wardmast.Quota.CodexQuota{
                 provider: "codex",
                 session_used_percent: 90,
                 limit_reached: true
               })

      assert Snapshot.normalize(%{not: "a quota row"}) == nil
      assert Snapshot.normalize(nil) == nil
    end

    test "existing dispatcher registries are unchanged with no extension installed" do
      # Order matters too: it is what the UI dropdowns and error messages show.
      assert Agents.valid_agent_types() == ~w(claude gemini codex grok)
      assert Workspace.valid_tracker_types() == ~w(none jira shortcut linear github gitlab)
      assert Workspace.valid_merger_strategies() == ~w(direct gitlab github)

      assert Routing.valid_policies() ==
               ~w(static by_priority by_difficulty by_budget round_robin)

      assert Agents.adapters() == %{
               claude: Wardmast.Agents.Claude,
               gemini: Wardmast.Agents.Gemini,
               codex: Wardmast.Agents.Codex,
               grok: Wardmast.Agents.Grok
             }

      assert Enum.sort(Agents.valid_agent_types()) == ~w(claude codex gemini grok)

      assert Enum.sort(Routing.valid_policies()) ==
               ~w(by_budget by_difficulty by_priority round_robin static)

      assert Enum.sort(Workspace.valid_tracker_types()) ==
               ~w(github gitlab jira linear none shortcut)

      assert Enum.sort(Workspace.valid_merger_strategies()) == ~w(direct github gitlab)

      assert Map.keys(Trackers.adapters()) |> Enum.sort() ==
               ~w(github gitlab jira linear none shortcut)a

      assert Map.keys(Mergers.adapters()) |> Enum.sort() == ~w(direct github gitlab)a
      assert Provider.adapter(:agy) == Wardmast.Sessions.Provider.Agy
    end
  end

  describe "an external extension" do
    setup do
      Extensions.load!([WardmastProFake.Extension])
    end

    test "is selected through the existing workspace config keys" do
      assert Agents.for_workspace(ws(%{"agent" => %{"type" => "acme"}})) == WardmastProFake.Agent
      assert Agents.for_type(:acme) == WardmastProFake.Agent
      assert "acme" in Agents.valid_agent_types()
      assert Agents.adapters()[:acme] == WardmastProFake.Agent

      assert Routing.policy_for_workspace(ws(%{"routing" => %{"policy" => "acme_fixed"}})) ==
               WardmastProFake.RoutingPolicy

      assert "acme_fixed" in Routing.valid_policies()
    end

    test "its quota rows are projected through :quota_snapshot" do
      row = %WardmastProFake.AcmeQuota{used: 0.7, captured_at: DateTime.utc_now()}

      assert %Snapshot{provider: "acme", utilization: 0.7, window_label: "day"} =
               Snapshot.normalize(row)

      assert Wardmast.Quota.Gate.stale?(row) == false

      # Uninstalled: the row is unknown again, and the gate fails open.
      Extensions.load!()
      assert Snapshot.normalize(row) == nil
    end

    test "two workspaces resolve different implementations of the same seam" do
      acme = ws(%{"agent" => %{"type" => "acme"}, "routing" => %{"policy" => "acme_fixed"}})
      core = ws(%{"agent" => %{"type" => "claude"}, "routing" => %{"policy" => "static"}})
      unset = ws(%{})

      assert Agents.for_workspace(acme) == WardmastProFake.Agent
      assert Agents.for_workspace(core) == Wardmast.Agents.Claude
      assert Agents.for_workspace(unset) == Wardmast.Agents.Claude

      assert Routing.policy_for_workspace(acme) == WardmastProFake.RoutingPolicy
      assert Routing.policy_for_workspace(core) == Wardmast.Agents.Routing.Static
      assert Routing.policy_for_workspace(unset) == Wardmast.Agents.Routing.Static

      assert Quota.gate_for_workspace(ws(%{"quota" => %{"gate" => "acme_budget"}})) ==
               WardmastProFake.QuotaGate

      assert Quota.gate_for_workspace(ws(%{"quota" => %{"on_exhaustion" => "continue"}})) ==
               Wardmast.Quota.Gate.Continue

      assert Quota.gate_for_workspace(ws(%{})) == Wardmast.Quota.Gate.Throttle
    end

    test "an unregistered quota.gate key falls back to the on_exhaustion shorthand" do
      assert Quota.gate_for_workspace(ws(%{"quota" => %{"gate" => "nope"}})) ==
               Wardmast.Quota.Gate.Throttle
    end

    test "config validation accepts its keys exactly while it is installed" do
      config = %{
        "agent" => %{"type" => "acme"},
        "routing" => %{"policy" => "acme_fixed"},
        "quota" => %{"gate" => "acme_budget"}
      }

      assert {:ok, _} = Ash.create(Workspace, %{name: "acme-ws", config: config})

      Extensions.load!()

      for bad <- [
            %{"agent" => %{"type" => "acme"}},
            %{"routing" => %{"policy" => "acme_fixed"}},
            %{"quota" => %{"gate" => "acme_budget"}}
          ] do
        assert {:error, _} = Ash.create(Workspace, %{name: "acme-gone", config: bad})
      end
    end

    test "quota.gate must name a registered gate" do
      assert {:error, err} =
               Ash.create(Workspace, %{name: "bad-gate", config: %{"quota" => %{"gate" => "zzz"}}})

      assert Exception.message(err) =~ "quota.gate"
    end
  end

  describe "load!/1 rules" do
    test "an extension may not shadow a core key" do
      assert_raise ArgumentError, ~r/agent.*claude.*already/s, fn ->
        Extensions.load!([WardmastProFake.ShadowingExtension])
      end
    end

    test "a failed load leaves the previous registry in place" do
      Extensions.load!([WardmastProFake.Extension])

      assert_raise ArgumentError, fn -> Extensions.load!([WardmastProFake.ShadowingExtension]) end

      assert {:ok, WardmastProFake.Agent} = Extensions.fetch(:agent, "acme")
    end

    test "a module missing a required callback of the seam is rejected" do
      assert_raise ArgumentError, ~r/choose\/3/, fn ->
        Extensions.load!([WardmastProFake.IncompleteExtension])
      end
    end

    test "an unknown seam is rejected" do
      assert_raise ArgumentError, ~r/no_such_seam/, fn ->
        Extensions.load!([WardmastProFake.UnknownSeamExtension])
      end
    end

    test "a module that is not an extension is rejected" do
      assert_raise ArgumentError, ~r/Wardmast.Extension/, fn -> Extensions.load!([Enum]) end

      assert_raise ArgumentError, ~r/not loaded|Wardmast.Extension/, fn ->
        Extensions.load!([WardmastProFake.DoesNotExist])
      end
    end

    test "load!/0 reads :wardmast, :extensions" do
      Application.put_env(:wardmast, :extensions, [WardmastProFake.Extension])
      on_exit(fn -> Application.delete_env(:wardmast, :extensions) end)

      Extensions.load!()
      assert {:ok, WardmastProFake.Agent} = Extensions.fetch(:agent, "acme")
    end

    test "mcp_tools/0 collects optional tool contributions" do
      assert Extensions.mcp_tools() == []
      Extensions.load!([WardmastProFake.ToolExtension])
      assert [%{name: "acme_tool"}] = Extensions.mcp_tools()
    end

    test "extension tools are in the catalog, callable, and tier-gated" do
      alias Wardmast.MCP.{Catalog, Scope}
      Extensions.load!([WardmastProFake.ToolExtension])
      on_exit(fn -> Extensions.load!([]) end)

      coord = %Scope{tier: :coordinator}
      worker = %Scope{tier: :worker}
      refine = %Scope{tier: :refine}

      assert "acme_tool" in Enum.map(Catalog.visible(coord), & &1.name)
      refute "acme_tool" in Enum.map(Catalog.visible(worker), & &1.name)
      refute "acme_tool" in Enum.map(Catalog.visible(refine), & &1.name)

      assert {:ok, %{"echo" => %{"a" => 1}}} = Catalog.call(coord, "acme_tool", %{"a" => 1})
      assert {:rpc_error, _, _} = Catalog.call(worker, "acme_tool", %{})
      assert {:rpc_error, _, _} = Catalog.call(refine, "acme_tool", %{})
    end

    test "a tool colliding with a core tool is rejected at registration" do
      assert_raise ArgumentError, ~r/ticket_show.*never shadow/, fn ->
        Extensions.load!([WardmastProFake.ShadowToolExtension])
      end
    end

    test "a malformed tool is rejected" do
      assert_raise ArgumentError, ~r/mcp_tools\/0 returned/, fn ->
        Extensions.load!([WardmastProFake.BadToolExtension])
      end
    end
  end
end

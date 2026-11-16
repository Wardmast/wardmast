defmodule Wardmast.Extensions.Core do
  @moduledoc """
  Wardmast's own adapters, registered the way an external package would.

  `Wardmast.Extensions` loads this first and applies exactly the same checks to
  it as to anything named in `config :wardmast, :extensions`. Because it is
  first, its keys are the ones an external extension cannot shadow.
  """

  @behaviour Wardmast.Extension

  alias Wardmast.Agents.Routing
  alias Wardmast.Extensions.Core.Values
  alias Wardmast.Mergers

  @impl true
  def contributions do
    [
      {:agent, "claude", Wardmast.Agents.Claude},
      {:agent, "gemini", Wardmast.Agents.Gemini},
      {:agent, "codex", Wardmast.Agents.Codex},
      {:agent, "grok", Wardmast.Agents.Grok},
      {:tracker, "none", Wardmast.Trackers.None},
      {:tracker, "jira", Wardmast.Trackers.Jira},
      {:tracker, "shortcut", Wardmast.Trackers.Shortcut},
      {:tracker, "linear", Wardmast.Trackers.Linear},
      {:tracker, "github", Wardmast.Trackers.GitHub},
      {:tracker, "gitlab", Wardmast.Trackers.Gitlab},
      {:merger, "direct", Mergers.Direct},
      {:merger, "gitlab", Mergers.Gitlab},
      {:merger, "github", Mergers.Github},
      {:routing_policy, "static", Routing.Static},
      {:routing_policy, "by_priority", Routing.ByPriority},
      {:routing_policy, "by_difficulty", Routing.ByDifficulty},
      {:routing_policy, "by_budget", Routing.ByBudget},
      {:routing_policy, "round_robin", Routing.RoundRobin},
      {:quota_gate, "throttle", Wardmast.Quota.Gate.Throttle},
      {:quota_gate, "continue", Wardmast.Quota.Gate.Continue},
      {:session_provider, "claude_code", Wardmast.Sessions.Provider.ClaudeCode},
      {:session_provider, "agy", Wardmast.Sessions.Provider.Agy},
      {:mcp_agent_config, "claude", Wardmast.MCP.AgentConfig.Claude},
      {:mcp_agent_config, "gemini", Wardmast.MCP.AgentConfig.Gemini},
      {:mcp_agent_config, "codex", Wardmast.MCP.AgentConfig.Codex},
      {:mcp_agent_config, "grok", Wardmast.MCP.AgentConfig.Grok},
      {:mcp_agent_config, "qwen", Wardmast.MCP.AgentConfig.Qwen},
      {:quota_snapshot, Atom.to_string(Wardmast.Quota.AnthropicQuota),
       Wardmast.Quota.Gate.Snapshot.Anthropic},
      {:quota_snapshot, Atom.to_string(Wardmast.Quota.CodexQuota),
       Wardmast.Quota.Gate.Snapshot.Codex},
      {:quota_snapshot, Atom.to_string(Wardmast.Quota.GoogleQuota),
       Wardmast.Quota.Gate.Snapshot.Google}
    ] ++ values()
  end

  defp values do
    types = ~w(task research bug feature epic chore decision)
    kinds = ~w(coordinator login)

    Enum.map(types, &{:issue_type, &1, Values}) ++ Enum.map(kinds, &{:session_kind, &1, Values})
  end
end

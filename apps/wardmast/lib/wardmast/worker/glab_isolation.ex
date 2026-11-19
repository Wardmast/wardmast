defmodule Wardmast.Worker.GlabIsolation do
  @moduledoc """
  Keeps a worker's `glab` away from the operator's OAuth login (#1545).

  glab's GitLab OAuth refresh token rotates on use. A host-run worker (Claude,
  Codex, Grok, ... held only by the permission layer) inherits the operator's
  `HOME`, so a bare `glab mr view` would load `~/.config/glab-cli/config.yml`,
  refresh, and rewrite or revoke the operator's token pair (`invalid_grant`).

  `env/0` points `GLAB_CONFIG_DIR` at an empty directory outside the operator's
  home, so glab sees only the injected `GITLAB_TOKEN` / `GITLAB_HOST`
  (`Worker.GitCredential.Material.env/2`) and can never load or rewrite the
  operator's login.
  """

  @doc "Env pairs that isolate glab's config dir from the operator's."
  @spec env() :: [{String.t(), String.t()}]
  def env, do: [{"GLAB_CONFIG_DIR", dir()}]

  @doc "The empty per-OS-user glab config directory (created on demand)."
  @spec dir() :: String.t()
  def dir do
    uid = System.get_env("USER") || "default"
    path = Path.join(System.tmp_dir!(), "arb-worker-glab-#{uid}")
    _ = File.mkdir_p(path)
    path
  end
end

defmodule Wardmast.Worker.GitCredentialGlabEnvTest do
  @moduledoc """
  #1545: a jailed worker's `glab` authenticates with the injected run token
  (`GITLAB_TOKEN`), never the operator's rotating OAuth login in
  `~/.config/glab-cli`.
  """
  use ExUnit.Case, async: true

  alias Wardmast.Worker.GitCredential.Material

  for kind <- [:gitlab_project_token, :gitlab_bot_token] do
    test "#{kind} injects GITLAB_TOKEN and GITLAB_HOST for glab" do
      m = %Material{
        kind: unquote(kind),
        token: "glpat-run",
        host: "gitlab.example.com",
        remote: "acme/tonic",
        username: "oauth2"
      }

      env = Material.env(m, nil)
      assert {"GITLAB_TOKEN", "glpat-run"} in env
      assert {"GITLAB_HOST", "gitlab.example.com"} in env
    end
  end

  test "GITLAB_TOKEN is delivered as a secret, never plain env" do
    assert "GITLAB_TOKEN" in Material.secret_env_names()
  end
end

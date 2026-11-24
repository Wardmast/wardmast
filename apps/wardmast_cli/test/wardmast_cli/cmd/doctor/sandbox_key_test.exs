defmodule WardmastCli.Cmd.Doctor.SandboxKeyTest do
  # bd-4j0nfe: a root `sandbox.backend` is read by nothing. `arb config get
  # sandbox` showed it, runs used `agent.security.sandbox.backend`, and doctor
  # said nothing.
  use ExUnit.Case, async: true

  alias WardmastCli.Cmd.Doctor.SandboxKey

  defp ws(name, config), do: %{"id" => "id-" <> name, "name" => name, "config" => config}

  test "root auto vs canonical bwrap: warns with the effective backend and the key it came from" do
    result =
      SandboxKey.check([
        ws("default", %{
          "sandbox" => %{"backend" => "auto"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "bwrap"}}}
        })
      ])

    assert result.status == :warn
    assert result.detail =~ "default"
    assert result.detail =~ "`sandbox.backend: auto` is ignored"
    assert result.detail =~ "effective backend bwrap"
    assert result.detail =~ "from `agent.security.sandbox.backend`"
    assert result.hint =~ "arb config set agent.security.sandbox.backend"
    assert result.hint =~ "ward server restart"
  end

  test "names the built-in default when the canonical key is unset" do
    result = SandboxKey.check([ws("fresh", %{"sandbox" => %{"backend" => "podman"}})])

    assert result.status == :warn
    assert result.detail =~ "`sandbox.backend: podman` is ignored"
    assert result.detail =~ "effective backend bwrap (the default"
  end

  test "a root key that agrees with the canonical one is still flagged as dead config" do
    result =
      SandboxKey.check([
        ws("agree", %{
          "sandbox" => %{"backend" => "auto"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "auto"}}}
        })
      ])

    assert result.status == :warn
    assert result.detail =~ "agree"
    assert result.detail =~ "effective backend auto"
    refute result.detail =~ "is ignored"
  end

  test "ok when no workspace carries a root sandbox key" do
    result =
      SandboxKey.check([
        ws("clean", %{"agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}})
      ])

    assert result.status == :ok
    refute result.hint
  end

  test "lists every offending workspace" do
    result =
      SandboxKey.check([
        ws("a", %{"sandbox" => %{"backend" => "auto"}}),
        ws("b", %{}),
        ws("c", %{"sandbox" => %{"egress" => "none"}})
      ])

    assert result.status == :warn
    assert result.detail =~ "2 workspaces"
    assert result.detail =~ "a:"
    assert result.detail =~ "c:"
    refute result.detail =~ "b:"
  end
end

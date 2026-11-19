defmodule Wardmast.Sessions.InstructionsDoctrineTest do
  @moduledoc """
  bd-6dpdwm — the session `CLAUDE.md` renders its doctrine from the one bundled
  source (`Wardmast.Doctrine`), and the live-checkout warning appears only when
  the installation actually configured a primary checkout.
  """
  use ExUnit.Case, async: false

  alias Wardmast.Doctrine
  alias Wardmast.Sessions.Instructions
  alias Wardmast.Sessions.Session

  defp session(overrides \\ []) do
    struct!(
      %Session{
        id: "sess1234",
        cwd: "/srv/example/sessions/sess1234/workspace",
        workspace_id: nil,
        can_dispatch: false
      },
      overrides
    )
  end

  describe "single source" do
    for can_dispatch <- [true, false] do
      test "embeds every bundled section verbatim (can_dispatch: #{can_dispatch})" do
        can_dispatch = unquote(can_dispatch)
        checkout = "/srv/example/checkout"

        doc =
          Instructions.render(session(), primary_checkout: checkout, can_dispatch: can_dispatch)

        assigns = %{can_dispatch: can_dispatch, primary_checkout: checkout}

        for name <- Doctrine.sections() do
          assert doc =~ Doctrine.render(name, assigns),
                 "session instructions do not embed the bundled #{name} section verbatim"
        end
      end
    end

    # bd-7p6a9o: a session kind's own instruction set (the pair session's) is
    # rendered instead of the coordinator doctrine, never into it.
    test "never embeds a session kind's own instruction set" do
      assert :pair in Doctrine.session_sets()

      for can_dispatch <- [true, false], name <- Doctrine.session_sets() do
        doc = Instructions.render(session(), primary_checkout: nil, can_dispatch: can_dispatch)

        refute doc =~ Doctrine.render(name, %{can_dispatch: can_dispatch}),
               "coordinator session instructions embed the #{name} session instruction set"
      end
    end

    test "carries the command reference and the filing conventions" do
      doc = Instructions.render(session(), primary_checkout: nil)

      assert doc =~ "## Command reference"
      assert doc =~ "`arb ticket create <title>`"
      assert doc =~ "D3 Hard"
      assert doc =~ "`issue_type` signals whether a PR is expected"
      assert doc =~ "## Concepts"
    end

    test "never claims Wardmast has no memory subsystem while mounting memory/shared" do
      doc = Instructions.render(session(), primary_checkout: nil)

      assert doc =~ "memory/shared"
      refute doc =~ ~r/no memory subsystem/i
    end
  end

  describe "the live-checkout warning is rendered only when primary_checkout is configured" do
    setup do
      prior_env =
        for k <- ["WARDMAST_PRIMARY_CHECKOUT", "ARB_HOME", "HOME"], do: {k, System.get_env(k)}

      prior_cfg = Application.get_env(:wardmast, :primary_checkout)

      home = Path.join(System.tmp_dir!(), "instr_home_#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      System.put_env("HOME", home)
      System.delete_env("WARDMAST_PRIMARY_CHECKOUT")
      System.delete_env("ARB_HOME")

      on_exit(fn ->
        Enum.each(prior_env, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)

        case prior_cfg do
          nil -> Application.delete_env(:wardmast, :primary_checkout)
          v -> Application.put_env(:wardmast, :primary_checkout, v)
        end

        File.rm_rf(home)
      end)

      %{home: home}
    end

    test "configured: the warning names the configured path" do
      Application.put_env(:wardmast, :primary_checkout, "/srv/example/configured")

      doc = Instructions.render(session())

      assert doc =~ "The live checkout is off limits"
      assert doc =~ "/srv/example/configured"
    end

    test "not configured: no warning, and no ~/dev/arbiter default is invented", %{home: home} do
      Application.delete_env(:wardmast, :primary_checkout)

      doc = Instructions.render(session())

      refute doc =~ "off limits"
      refute doc =~ "hot-reload"
      refute doc =~ Path.join(home, "dev/arbiter")
      refute doc =~ "dev/arbiter"
      assert doc =~ "Repository work, if the operator asks for it"
    end

    test "an explicit primary_checkout: nil option also omits the warning" do
      Application.put_env(:wardmast, :primary_checkout, "/srv/example/configured")

      doc = Instructions.render(session(), primary_checkout: nil)

      refute doc =~ "off limits"
      refute doc =~ "/srv/example/configured"
    end
  end
end

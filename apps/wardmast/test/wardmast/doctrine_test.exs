defmodule Wardmast.DoctrineTest do
  @moduledoc """
  bd-6dpdwm — the bundled coordinator doctrine is one server-side source
  (`apps/wardmast/priv/doctrine/*.md.eex`) that feeds both the session
  `CLAUDE.md` (`Wardmast.Sessions.Instructions`) and `arb init`'s `AGENTS.md`.

  It ships to every installation, so it must be installation-agnostic: the
  denylist test below fails if a name, hostname, home path or personal
  identifier leaks into any bundled section, rendered under every combination
  of assigns the two consumers use.
  """
  use ExUnit.Case, async: true

  alias Wardmast.Doctrine

  @priv_dir Path.expand("../../priv/doctrine", __DIR__)

  # Lowercased; matched case-insensitively against the *rendered* output and
  # against the raw template source.
  @denylist [
    # installation / workspace / host names
    "mesaana",
    "admiral",
    "vstim",
    "emricare",
    "tonic",
    "oryx",
    # personal names and handles
    "ryan",
    "born",
    # persona text the operator never wants in generated docs
    "darth",
    "sith",
    # host-specific paths — the doctrine must not assume a home directory
    "/home/",
    "/users/",
    "~/dev/",
    "localhost",
    "127.0.0.1"
  ]

  defp assign_matrix do
    for can_dispatch <- [true, false],
        checkout <- [nil, "/srv/example/checkout"],
        prefix <- [nil, "ex"] do
      %{can_dispatch: can_dispatch, primary_checkout: checkout, domain_prefix: prefix}
    end
  end

  describe "bundled sections" do
    test "the doctrine ships the expected sections" do
      for name <- [:role, :research, :memory, :filing, :concepts, :commands, :checkout] do
        assert name in Doctrine.sections(), "missing doctrine section #{inspect(name)}"
      end
    end

    test "every section source file under priv/doctrine is a registered section" do
      files = @priv_dir |> Path.join("*.md.eex") |> Path.wildcard()
      assert length(files) == length(Doctrine.sections())
    end

    test "render/2 raises for an unknown section" do
      assert_raise FunctionClauseError, fn -> Doctrine.render(Enum.at([:nope], 0), %{}) end
    end
  end

  describe "leak denylist" do
    test "no bundled template source contains a denylisted string" do
      # Recursive: the session instruction sets live in priv/doctrine/sessions/.
      files = @priv_dir |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)
      assert Enum.any?(files, &(Path.basename(Path.dirname(&1)) == "sessions"))

      for file <- files do
        source = file |> File.read!() |> String.downcase()

        for needle <- @denylist do
          refute source =~ needle, "#{Path.basename(file)} contains denylisted #{inspect(needle)}"
        end
      end
    end

    test "no rendered section contains a denylisted string under any assigns" do
      for assigns <- assign_matrix(), name <- Doctrine.sections() ++ Doctrine.session_sets() do
        rendered = name |> Doctrine.render(assigns) |> String.downcase()

        for needle <- @denylist do
          refute rendered =~ needle,
                 "section #{name} rendered with #{inspect(assigns)} contains denylisted #{inspect(needle)}"
        end
      end
    end

    test "the denylist test is not vacuous: a leaked string would be caught" do
      leaked = "see /home/someone/dev/thing"
      assert Enum.any?(@denylist, &(String.downcase(leaked) =~ &1))
    end
  end

  describe "the live-checkout warning" do
    test "renders only when a primary checkout is configured" do
      with_checkout = Doctrine.render(:checkout, %{primary_checkout: "/srv/example/checkout"})
      without = Doctrine.render(:checkout, %{primary_checkout: nil})

      assert with_checkout =~ "The live checkout is off limits"
      assert with_checkout =~ "/srv/example/checkout"
      assert with_checkout =~ "hot-reload"

      refute without =~ "off limits"
      refute without =~ "hot-reload"
      refute without =~ "/srv/example/checkout"
    end

    test "the unconfigured arm invents no path" do
      without = Doctrine.render(:checkout, %{primary_checkout: nil})
      refute without =~ "~/"
      refute without =~ "dev/arbiter"
    end
  end

  describe "memory wording" do
    test "says workers start cold without claiming Wardmast has no memory at all" do
      memory = Doctrine.render(:memory, %{})

      refute memory =~ ~r/no memory subsystem/i
      assert memory =~ ~r/nothing compounds/i
      assert memory =~ "memory/shared"
      assert memory =~ ~r/workers?.{0,80}(cold|do not read|never read)/is
    end
  end

  describe "command reference, concepts and filing conventions" do
    test "the command reference lists the core verbs with their MCP twins" do
      commands = Doctrine.render(:commands, %{can_dispatch: true, domain_prefix: "ex"})

      for needle <- [
            "arb prime",
            "arb ticket create",
            "ticket_create",
            "arb worker list",
            "worker_list",
            "ex-1 blocks ex-2"
          ] do
        assert commands =~ needle
      end

      assert commands =~ "worker_dispatch"
    end

    test "the command reference omits dispatch when the session cannot dispatch" do
      commands = Doctrine.render(:commands, %{can_dispatch: false, domain_prefix: nil})

      refute commands =~ "worker_dispatch"
      refute commands =~ "arb ticket dispatch"
      assert commands =~ "<prefix>-1 blocks <prefix>-2"
    end

    test "concepts define ticket, epic, worker, repo and workspace" do
      concepts = Doctrine.render(:concepts, %{domain_prefix: nil})

      for term <- ["Ticket", "Epic", "Worker", "Repo", "Workspace"] do
        assert concepts =~ "**#{term}**"
      end
    end

    test "filing conventions cover difficulty D0..D5 and every issue_type" do
      filing = Doctrine.render(:filing, %{})

      for d <- ~w(D0 D1 D2 D3 D4 D5), do: assert(filing =~ d)

      for type <- ~w(bug feature chore research task decision epic) do
        assert filing =~ "`#{type}`"
      end

      assert filing =~ "--difficulty"
      assert filing =~ "--priority"
      assert filing =~ "ticket_update_progress"
      assert filing =~ ~r/no PR/i
    end
  end

  describe "the pair instruction set (bd-7p6a9o)" do
    test "ships as a session instruction set, apart from the coordinator doctrine" do
      assert :pair in Doctrine.session_sets()
      refute :pair in Doctrine.sections()

      session_files = @priv_dir |> Path.join("sessions/*.md.eex") |> Path.wildcard()
      assert length(session_files) == length(Doctrine.session_sets())
    end

    test "collaborate, explain changes, ask before large rewrites, stay inside the ACs" do
      pair = Doctrine.render(:pair, %{})

      assert pair =~ "**Collaborate.**"
      assert pair =~ "**Explain your changes.**"
      assert pair =~ "**Ask before large rewrites.**"
      assert pair =~ "**Stay inside the ticket's acceptance criteria.**"
    end

    test "is not the router doctrine" do
      pair = Doctrine.render(:pair, %{can_dispatch: true})
      role = Doctrine.render(:role, %{can_dispatch: true})

      refute pair =~ "worker_dispatch"
      refute pair == role
      assert pair =~ ~r/not the\s+coordinator's job/
    end

    test "states the write scope and fills in what it is given" do
      bare = Doctrine.render(:pair, %{})
      assert bare =~ "the default branch"
      assert bare =~ "never force-push"

      filled =
        Doctrine.render(:pair, %{
          worktree: "/srv/example/wt",
          branch: "feature/ex-1-thing",
          target_branch: "trunk"
        })

      assert filled =~ "(`/srv/example/wt`)"
      assert filled =~ "(`feature/ex-1-thing`)"
      assert filled =~ "Never push to `trunk`"
    end

    test "Done runs the worker's completion path, and the review bar does not drop" do
      pair = Doctrine.render(:pair, %{})

      assert pair =~ "`pair-authored`"
      assert pair =~ "ReviewGate"
      assert pair =~ "review bar does not drop"
      assert pair =~ ~r/without\*\* Done leaves the branch and the\s+worktree/
    end
  end
end

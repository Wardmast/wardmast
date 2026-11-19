defmodule Wardmast.Sessions.Instructions do
  @moduledoc """
  The generated `CLAUDE.md` a provisioned session boots with (bd-aprlbb,
  RFC §9.1 — "generated: role, workspace binding, guardrails") — or, for an
  agy session, the `GEMINI.md` (bd-7xuvfl). The doctrine is the same; what
  differs per provider is only the host's own mechanics: where the MCP config
  sits (`.mcp.json` in the cwd vs. `mcp_config.json` under the session's own
  `$HOME`) and whether there is a persistent Monitor tool to arm the event
  stream with (Claude Code has one, agy does not).

  This is **§10.2 layer 4**, "belt and braces": the RFC's own note is that the
  dispatched-worker prompt already carries the live-checkout warning and it
  demonstrably helps. It is the weakest of the four layers on its own and the
  only one that reaches a session *before* it acts, which is why it ships
  alongside the other three rather than instead of them.

  It also carries the §9.4 memory doctrine, because the read-only convention on
  the shared layer is enforced by this file and nothing else: symlinked layers
  are writable by the user the session runs as, so "a session never writes into
  the shared layer" is a rule the agent follows, not a permission it lacks.

  For the same reason it carries the **role** doctrine (bd-5v8f8l): a
  coordinator files bugs rather than fixing them, and delegates the digging.
  `Wardmast.Sessions.Guards` cannot help here even though it is the stronger
  layer. Its two predicates are about API calls a session makes *to Wardmast*
  (self-kill, restart budget), and the write this rule is about never reaches
  Wardmast at all — it is an editor touching a worktree under the session's own
  directory. That worktree is also exactly where a session legitimately works
  when the operator *has* asked it to make a change, so the offending write and
  the wanted write are the same write to the same path; the only thing
  separating them is whether the operator asked, which no path- or tool-scoped
  rule can observe. Hence prompt-only, placed early, and fenced by
  `Wardmast.Sessions.InstructionsTest` so it cannot silently go missing again
  the way it silently was missing.

  The doctrine text — role, research discipline, memory wording, concepts, the
  command reference, the filing conventions and the live-checkout warning —
  lives in **one place**, `apps/wardmast/priv/doctrine/*.md.eex`, rendered by
  `Wardmast.Doctrine`. `WardmastCli.Cmd.Init` embeds the same files into the
  `AGENTS.md` that `arb init` scaffolds, so the two cannot drift. What stays
  here is only what is genuinely per-session: the workspace binding, the MCP
  config location, and the event-monitor mechanics.
  """

  alias Wardmast.Agents.Gemini.ConfigDir, as: AgyConfigDir
  alias Wardmast.Config.Paths
  alias Wardmast.Doctrine
  alias Wardmast.MCP.RefinePolicy
  alias Wardmast.Sessions.Layout
  alias Wardmast.Sessions.RefineDoctrine
  alias Wardmast.Sessions.Session

  @doc """
  Render the instructions for a session.

  ## Options

    * `:primary_checkout` — the live source tree to warn about; `nil` omits the
      warning rather than printing a placeholder path (an invented path is
      worse than no rule). When the option is absent it defaults to
      `Wardmast.Config.Paths.explicit_primary_checkout/0` — the warning renders
      only for an installation that actually configured one, never for a
      guessed `~/dev/arbiter`.
    * `:mcp_server_name` — the `.mcp.json` server key, default `"arbiter"`.
    * `:can_dispatch` — overrides the session row's value, for rendering a
      preview before the row exists.
    * `:refine` — presence switches this to the **refine variant** (bd-980x89):
      a map carrying `:issue` (the bound issue, required), `:epic` (its parent,
      or `nil`), `:edges` (a list of `%{type:, direction:, id:, title:}` maps,
      default `[]`), `:repo_checkout` (the read-only checkout path, or `nil`)
      and `:workspace` (an `Wardmast.Tasks.Workspace.t()` or `nil`, used both
      for display and to resolve `Wardmast.Sessions.RefineDoctrine`'s
      per-workspace override). Absent `:refine`, `render/2` produces exactly
      the coordinator-session instructions above — the pre-refine behavior.
    * `:pair` — a map here switches this to the **pair variant** (bd-7p6a9o),
      ahead of `:refine`: `:issue` (the bound ticket, required), `:worktree`
      (default: the session's cwd), `:branch` and `:target_branch`. Its
      doctrine is the bundled `pair` session instruction set
      (`priv/doctrine/sessions/pair.md.eex`), never the coordinator doctrine.
  """
  @spec render(Session.t(), keyword()) :: String.t()
  def render(%Session{} = session, opts \\ []) do
    case {Keyword.get(opts, :pair), Keyword.get(opts, :refine)} do
      {pair, _refine} when is_map(pair) -> render_pair(session, pair, opts)
      {nil, nil} -> render_coordinator(session, opts)
      {nil, refine} -> render_refine(session, refine, opts)
    end
  end

  # bd-7p6a9o: the pair variant. Its doctrine is the bundled `pair` session
  # instruction set (`priv/doctrine/sessions/`) — collaborate, explain, ask
  # before large rewrites, stay inside the ACs — and deliberately *not* the
  # router doctrine the coordinator variant renders: a pair session does the
  # work a coordinator would route.
  defp render_pair(%Session{} = session, pair, opts) do
    issue = Map.fetch!(pair, :issue)
    worktree = Map.get(pair, :worktree) || session.cwd
    branch = Map.get(pair, :branch)
    target = Map.get(pair, :target_branch)

    primary_checkout =
      Keyword.get(opts, :primary_checkout, Paths.explicit_primary_checkout())

    """
    # Wardmast pair session `#{session.id}`

    You are a **pair session**: a #{host(session)} session Wardmast launched
    into this ticket's own git worktree so that you and the operator can work
    ticket #{issue_ref(issue)} **together**. You are not the coordinator and
    you are not a dispatched worker: the operator is here with you, and you
    cannot dispatch anyone else.

    This file is **generated on every launch** — edits to it are lost.

    #{bound_ticket_section(issue)}

    ## Where you are

    * **worktree** — `#{worktree}` (your working directory)
    * **branch** — #{format_code(branch)}
    * **base** — #{format_code(target)} — the branch the PR merges into
    * **MCP** — the `.mcp.json` in the worktree carries this ticket's own
      token (git never sees the file). It reads and writes this ticket only,
      and it stops working when this session ends.
    #{pair_checkout_line(primary_checkout)}

    #{Doctrine.render(:pair, %{worktree: worktree, branch: branch, target_branch: target})}
    """
  end

  defp bound_ticket_section(issue) do
    """
    ## The ticket

    * **id** — `#{field(issue, :id)}`
    * **title** — #{field(issue, :title)}
    * **type** — `#{field(issue, :issue_type)}`
    * **repo** — #{format_field(field(issue, :repo))}

    ### Description

    #{format_field(field(issue, :description))}

    ### Acceptance criteria — the scope of this session

    #{format_field(field(issue, :acceptance))}
    """
    |> String.trim()
  end

  defp pair_checkout_line(nil), do: ""

  defp pair_checkout_line(checkout) do
    "* **primary checkout** — `#{checkout}` is the live source tree; never edit it, " <>
      "never run git in it."
  end

  defp format_code(nil), do: "_(unknown)_"
  defp format_code(value), do: "`#{value}`"

  defp render_coordinator(%Session{} = session, opts) do
    id = session.id
    # The row's cwd wins where it is set — the agent is told where it actually
    # is, and where its `.mcp.json` actually sits (it lives in the cwd; see
    # `Wardmast.Sessions.Layout.mcp_config_path/1`).
    cwd = session.cwd || Layout.workspace_dir(id)
    mcp_config = mcp_config_path(session, cwd)
    can_dispatch = Keyword.get(opts, :can_dispatch, session.can_dispatch)
    server = Keyword.get(opts, :mcp_server_name, "arbiter")

    # Only an explicitly configured checkout earns the live-checkout warning;
    # `Paths.primary_checkout/0`'s `~/dev/arbiter` guess is for the path guard,
    # not for prose (an invented path is worse than no rule).
    primary_checkout = Keyword.get(opts, :primary_checkout, Paths.explicit_primary_checkout())

    doctrine = %{
      can_dispatch: can_dispatch,
      primary_checkout: primary_checkout,
      domain_prefix: nil
    }

    """
    # Wardmast coordinator session `#{id}`

    You are a **coordinator session**: an interactive #{host(session)} session that
    Wardmast provisioned and launched into a tmux pane, reachable from the
    Wardmast dashboard in a browser. You are not a dispatched worker and you have
    no single assigned task. You drive the fleet.

    This file is **generated on every launch** — edits to it are lost. Durable
    notes go in `memory/candidates/` (see "Memory", below).

    #{Doctrine.render(:role, doctrine)}

    #{Doctrine.render(:research, doctrine)}

    ## Your workspace

    #{workspace_section(session)}

    Your working directory is `#{cwd}`. It is a fresh directory that Wardmast
    created for this session — deliberately **not** a checkout of anything. The
    only thing in it is #{cwd_contents(session)}.

    #{Doctrine.render(:checkout, doctrine)}

    ## Talking to Wardmast

    `#{mcp_config}` registers the Wardmast MCP server (`#{server}`) with a
    bearer token minted for **this session only**. It is revoked the moment the
    session ends or is killed, so a copy of it is worth nothing afterwards —
    but it is a live credential while you run: never paste it into a file, a
    commit, a PR body, or your own output.

    #{dispatch_section(can_dispatch)}

    You cannot kill your own session through Wardmast's API — the call would
    terminate you mid-call. Ask the operator to kill it from the dashboard or
    the CLI.

    #{Doctrine.render(:commands, doctrine)}

    #{Doctrine.render(:concepts, doctrine)}

    #{Doctrine.render(:filing, doctrine)}

    #{event_monitor_section(session)}

    ## Memory

    * `memory/shared/` — the operator's memory layers, mounted **read-only**,
      one subdirectory per type: `user/`, `feedback/`, `reference/` (always
      present) and `project/` (populated only when this session is bound to a
      workspace, and only with that workspace's own memories — never another
      workspace's). Read them freely. **Never write, edit, or delete anything
      under it.** The source is a single unlocked file per memory and other
      sessions are reading it concurrently; a write from here is a
      last-write-wins clobber of somebody else's memory.
    * `memory/candidates/` — your write space. Anything you learn that is worth
      keeping goes here, one fact per file. A later promotion step (not yours)
      reviews candidates into the shared layer. If a candidate is scoped to
      this session's workspace rather than being general operator/behavioural
      context, tag it `metadata.type: project` with `metadata.workspace_id`
      set to this workspace's id — an untagged or mistagged candidate simply
      never mounts for anyone, so when in doubt, tag it.

    #{Doctrine.render(:memory, doctrine)}

    ## Process discipline

    Never use `pkill`, `killall`, `fuser -k`, or any other name- or
    pattern-matching kill. Process command lines are visible host-wide: a
    pattern that matches your own process matches the live Wardmast server and
    every running worker just as easily. Capture an exact PID and kill that.
    """
  end

  defp host(%Session{provider: :agy}), do: "agy (Antigravity)"
  defp host(%Session{}), do: "Claude Code"

  # agy reads MCP servers from `$HOME/.gemini/config/mcp_config.json` only
  # (bd-m8geh4), and an agy session's `$HOME` is its own.
  defp mcp_config_path(%Session{provider: :agy, id: id}, _cwd),
    do: Path.join(Layout.home_dir(id), AgyConfigDir.mcp_config_path())

  defp mcp_config_path(%Session{}, cwd), do: Path.join(cwd, ".mcp.json")

  defp cwd_contents(%Session{provider: :agy}), do: "this `GEMINI.md`"
  defp cwd_contents(%Session{}), do: "the `.mcp.json` below"

  # agy has no persistent-monitor tool and no `SessionStart` hook, and its
  # `run_command` backgrounds a long-running command and moves on — so an
  # agy session is told to poll rather than handed a stream it cannot hold.
  defp event_monitor_section(%Session{provider: :agy}) do
    """
    ## Events

    There is no event monitor in this session: agy has no persistent tool to
    hold a streaming connection open, and a backgrounded infinite loop would
    only outlive the turn that started it. Poll instead — call
    `coordinator_inbox` at the start of every turn, and whenever the operator
    asks what has happened, for the authoritative unread view. The inbox is
    shared across sessions, so decide what concerns you and ignore the rest.
    """
    |> String.trim()
  end

  defp event_monitor_section(%Session{}) do
    """
    ## Event monitor

    A `SessionStart` hook already told you to do this, but in case it fired
    before this file did: run `$ARB_SESSION_ROOT/monitor.sh` via the **Monitor**
    tool with `persistent: true`, not background Bash — an infinite loop never
    exits, so it never produces a notification for `run_in_background` to
    surface. It streams `/events` (inbox, review_gate, worker_done,
    worker_failed) using your own session token; it never calls
    `arb mcp token mint`.

    Treat every line it prints as a **wake-up signal only**, not the payload:
    call `coordinator_inbox` for the authoritative unread view before acting on
    anything. The stream is shared — **every session receives every event**,
    including ones filed for other sessions' tasks — so decide what concerns
    you and ignore the rest.

    `curl`'s own `--max-time` closes the connection periodically; re-arm the
    monitor whenever it exits (token expiry or a network blip). It resumes
    with `since=<last cursor>` automatically, so re-arming never re-delivers
    what you already saw or drops what arrived while it was down.
    """
    |> String.trim()
  end

  # ---- the refine variant (bd-980x89) --------------------------------------

  defp render_refine(%Session{} = session, refine, _opts) do
    issue = Map.fetch!(refine, :issue)
    epic = Map.get(refine, :epic)
    edges = Map.get(refine, :edges, [])
    repo_checkout = Map.get(refine, :repo_checkout)
    workspace = Map.get(refine, :workspace)

    """
    # Wardmast refine session `#{session.id}`

    You are a **refine session**: a browser-hosted agent session bound to
    **one Backlog issue**, launched so you and the operator can shape it
    together into a properly specified, broken-down, promotable ticket. You
    are not a dispatched worker: you never implement the issue, and you
    cannot dispatch anyone else to.

    This file is **generated on every launch** — edits to it are lost.

    #{bound_issue_section(issue, epic)}

    #{edges_section(edges)}

    #{refine_workspace_section(workspace)}

    #{repo_checkout_section(repo_checkout)}

    #{permissions_section()}

    ## This session ends when the bound issue is promoted

    Once #{issue_ref(issue)} — and any children you filed under it — is
    promoted, this session's job is done; there is nothing further for you to
    do here. Write a short refinement summary to the issue **before**
    promoting.

    #{RefineDoctrine.content(workspace)}
    """
  end

  defp bound_issue_section(issue, epic) do
    """
    ## The bound issue

    * **id** — `#{field(issue, :id)}`
    * **title** — #{field(issue, :title)}
    * **type** — `#{field(issue, :issue_type)}`
    * **priority** — #{format_field(field(issue, :priority))}
    * **difficulty** — #{format_field(field(issue, :difficulty))}
    * **repo** — #{format_field(field(issue, :repo))}
    * **state** — `#{field(issue, :state)}`
    * **tracker_ref** — #{format_field(field(issue, :tracker_ref))}

    ### Current description

    #{format_field(field(issue, :description))}

    ### Current acceptance

    #{format_field(field(issue, :acceptance))}

    #{epic_section(epic)}
    """
    |> String.trim()
  end

  defp epic_section(nil) do
    "### Parent epic\n\nNone — this issue has no parent epic."
  end

  defp epic_section(epic) do
    """
    ### Parent epic

    * **id** — `#{field(epic, :id)}`
    * **title** — #{field(epic, :title)}
    """
    |> String.trim()
  end

  defp edges_section([]) do
    """
    ## Edges

    None yet.
    """
    |> String.trim()
  end

  defp edges_section(edges) do
    lines =
      Enum.map(edges, fn edge ->
        "* `#{field(edge, :type)}` #{field(edge, :direction)} `#{field(edge, :id)}` — #{field(edge, :title)}"
      end)

    """
    ## Edges

    #{Enum.join(lines, "\n")}
    """
    |> String.trim()
  end

  defp refine_workspace_section(nil) do
    """
    ## Workspace

    No workspace metadata was provided for this render.
    """
    |> String.trim()
  end

  defp refine_workspace_section(workspace) do
    """
    ## Workspace

    * **id** — `#{field(workspace, :id)}`
    * **name** — #{format_field(field(workspace, :name))}
    * **prefix** — #{format_field(field(workspace, :prefix))}
    """
    |> String.trim()
  end

  defp repo_checkout_section(nil) do
    """
    ## Repository checkout

    No read-only checkout was provided for this render. Ask the operator for
    one before reading source for this issue.
    """
    |> String.trim()
  end

  defp repo_checkout_section(path) do
    """
    ## Repository checkout

    `#{path}` is a **read-only** checkout of the issue's repo, for context.
    Reading it is fine and is usually all refinement needs; there is no live
    server behind it and nothing here writes to it.
    """
    |> String.trim()
  end

  defp permissions_section do
    """
    ## What you may and may not do

    Your Wardmast MCP token is bound to this one workspace and this one issue
    and cannot reach anything else.

    **You may:**

    * Read broadly for context: the bound issue, its epic, related issues,
      edges, workspace config, skills, and the issue's repo via the read-only
      checkout above.
    * Edit the bound issue and any issue in its `parent_of` subtree — title,
      description, acceptance, `issue_type`, difficulty, priority, repo,
      `verify_after_deploy`.
    * File child issues (`ticket_create`). They land in Backlog, auto-linked
      `parent_of` from the bound issue.
    * Add edges (`dep_add`/`dep_remove`) touching the bound issue or its
      children.
    * Promote the bound issue and its children (`ticket_promote`), once the
      operator agrees in the conversation that they're ready, and only after
      their edges are written.

    Callable tools: `#{Enum.join(RefinePolicy.allowed(), "`, `")}`.

    **You may never:**

    * Dispatch, close, stop, or resume workers — `can_dispatch` is hard-wired
      false on this session's token.
    * Change installation or workspace configuration.
    * Edit or promote an issue outside the bound issue's subtree.
    """
    |> String.trim()
  end

  defp issue_ref(issue), do: "`#{field(issue, :id)}`"

  defp field(struct_or_map, key), do: Map.get(struct_or_map, key)

  defp format_field(nil), do: "_(none)_"
  defp format_field(""), do: "_(none)_"
  defp format_field(value) when is_boolean(value), do: to_string(value)
  defp format_field(value), do: to_string(value)

  defp workspace_section(%Session{workspace_id: nil}) do
    """
    This session is **cross-workspace**: its Wardmast token is not bound to one
    workspace, so tools that take a workspace need you to name it explicitly.
    """
    |> String.trim()
  end

  defp workspace_section(%Session{workspace_id: id}) do
    """
    This session is **bound to workspace `#{id}`**. Its Wardmast token cannot
    reach any other workspace; a cross-workspace request comes back as
    not-found, not as a permission error.
    """
    |> String.trim()
  end

  defp dispatch_section(true) do
    "Dispatching workers is **enabled** for this session, so a worker you " <>
      "dispatch can itself reach Wardmast. Watch for recursion."
  end

  defp dispatch_section(false) do
    "Dispatching workers is **disabled** for this session (the default). Ask " <>
      "the operator to relaunch with it enabled if you need it."
  end
end

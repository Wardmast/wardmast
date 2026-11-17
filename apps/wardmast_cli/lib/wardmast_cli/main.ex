defmodule WardmastCli.Main do
  @moduledoc """
  Escript entry point. The CLI uses a `ward <resource> <verb>` grammar (`wm` is
  a shorthand symlink; `arb` is a one-release deprecated shim that execs `ward`):
  the first token names a resource (or a flat meta command), the second the
  action on it.

  ## Resources

      ward ticket list     [--state ...] [--type ...] [--priority ...] [--labels ...] [--tracker]
      ward ticket show     <id>
      ward ticket create   <title> [--description ...] [--priority ...] [--type ...]
                                   [--acceptance a | --acceptance-file PATH]
                                   [--notes t] [--qa-notes t] [--deployment-notes t]
                                   [--deps id1,id2] [--labels a,b] [--parent <parent-id>]
                                   [--auto-close] [--tracker-ref R] [--tracker-type T]
                                   [--tracker-context-type T] [--tracker-context-ref R]
                                   [--require-provider p | --exclude-provider p]
                                   [--depends-on id1,id2] [--blocks id1,id2]
      ward ticket create   --from-file <batch.json|batch.yaml|-> [--promote] [--force]   (atomic graph)
      ward ticket update   <id> [--title ...] [--priority N] [--difficulty N] [--type T]
                                   [--description d] [--notes t | --append-notes t]
                                   [--acceptance a | --acceptance-file PATH]
                                   [--qa-notes text] [--deployment-notes text]
                                   [--pr-body text] [--pr-ref R] [--target-branch B]
                                   [--tracker-ref R] [--tracker-type T]
                                   [--tracker-context-type T] [--tracker-context-ref R]
                                   [--auto-close | --no-auto-close]
                                   [--require-provider p | --exclude-provider p |
                                    --clear-provider-constraint]
                                   [--permission p] [--remove-permission p]
                                   ("" clears a field; `ward ticket update --help` lists all)
      ward ticket close    <id> [--reason ...] [--no-upstream]
      ward ticket reopen   <id>
      ward attention       [--owner coordinator|operator] [--workspace <id|name>]
                                   the open attention queue (tickets needing someone)
      ward verify          <id> --observed "<evidence>" | --failed "<evidence>"   (== ward ticket verify)
      ward ticket permit   <id> <permission> [--deny] [--reason "<why>"]
                                   grant or deny a permission a worker asked for (operator-only
                                   bindings need operator proof; a network: grant is live)
      ward ticket verify   <id> --observed "<evidence>" | --failed "<evidence>"
                                   record the post-merge restart-and-observe result
                                   for a ticket in state verifying
      ward ticket resolve  <id> --accept-as-is|--amend|--send-back|--reject "<reasoning>"
                                   [--gate review_gate|notes_gate|commit_gate] [--round N]
                                   [--fix-round-attempt N]
                                   record your answer to a gate escalation — what the
                                   coordinator decided and why (bd-4qjl0q)
      ward ticket claim    <ref> [--force] [--repo <repo>]
      ward ticket sync     [--dry]
      ward ticket ready
      ward ticket dispatch <id> [<repo>] [--provider claude|gemini|codex|grok | --no-agent]
                           [--model <name>] [--force] [--over-cap]
                           [--force-quota [--force-quota-reason <why>]]
                                   (== ward dispatch; --with-claude/--with-gemini are deprecated aliases)

                                   `ward issue …` is a deprecated alias for `ward ticket …`:
                                   it still runs, and prints a one-line note on stderr.

      ward epic floor      <id> P1|P2|P3|none
                                   set or clear an epic's priority floor: its children
                                   are scheduled as min(own priority, floor). Operator
                                   and coordinator only; P0 is never a floor.

      ward worker list
      ward worker show     <task-id>
      ward worker runs     [<task-id>] [--kind K] [--state S] [--outcome O] [--before ISO] [--limit N]
      ward worker runs     --run <run-id> | <task-id> --corpus
      ward worker log      <task-id> [--run <run-id>] [--tail N]
      ward worker prompt   <task-id> [--run <run-id>]
      ward worker stop     <task-id>
      ward worker resume   <task-id> [<repo> | --repo <repo>] [--model <name>] [--force]
                           [--force-quota [--force-quota-reason <why>]] [--mode session|briefing]
      ward worker review   <task-id> [--repo <repo>] [--model <name>] [--force] [--automation <mode>]
                           [--force-quota [--force-quota-reason <why>]]
      ward queue retry-auto-resolve <task-id>
      ward queue restart-watchdog   <task-id>
      ward queue rerun-ci           <task-id> [--mode <mode>] [--workflow <w>] [--input k=v]
      ward queue mark-ci-external   <task-id> <note...>
      ward review          <task-id> | --pr <url|number> [--report-only] [--force] [--follow-up|--no-follow-up]
                           [--scope diff|repo] [--automation <mode>] [--repo <repo>]
                           [--tracker-context-ref <ref> [--tracker-context-type <t>]]
      ward review list     [--status running|completed|failed] [--since <ts>] [--limit <n>]
      ward review show     <record-id>              proposed comments, numbered
      ward review transcript <record-id> [--tail <n>] [--no-prompt]
      ward review rounds   <task-id> [--limit <n>]  ReviewGate rounds + outcome
      ward review greenlight <record-id> [--select all|none|0,2] [--no-post-verdict]
      ward review resolve  <task-id> --amend "<reasoning>"   (== ward ticket resolve)

      ward repo list
      ward repo show       <name>

      ward skill list
      ward skill show      <id|name>
      ward skill create    <name> [--body ... | --body-file PATH | -] [--metadata JSON]
      ward skill update    <id|name> [--name NEW] [--body ... | --body-file PATH | -]
                                   [--metadata JSON]
      ward skill delete    <id|name> [--force]

      ward account list                              [--provider p] [--include-merged] [--include-deleted]
      ward account show    <ref>                      (uuid, provider:slug, or bare slug)
      ward account create  <provider> <slug>          [--label ...] [--plan ...] [--max-concurrent N]
                           [--disable] [--provider-account-ref ID] [--provider-org-ref ID] [quota flags]
      ward account set     <ref>                      [--label ...] [--plan ...] [--enable|--disable]
                           [--max-concurrent N|none] [--budget-split queue|fair] [--admission legacy|shadow|enforce|inherit] [--threshold-mode flat|paced]
                           [--throttle-threshold F]
                           [--weekly-threshold F] [--paced-floor F] [--weekly-paced-floor F]
                           [--pace-curve plateau|ramp] [--daily-burn-cap F|none] [--daily-burn-cap-mode shadow|enforce] [--weekly-warning-policy ignore|hold] [--window-seconds LABEL=SECONDS]
                           [--pace-exempt-priority 0..4|none] [--pace-exempt-threshold F]
                           [--weekly-pace-exempt-threshold F] [--unset QUOTA_KEY]
      ward account attach  <workspace> <provider> <ref> [--share N] [--weight N]
      ward account detach  <workspace> <ref>
      ward account rotate  <ref> --kind k --env-var V (--secret S | --secret-file PATH | -)
      ward account merge   <from-ref> --into <into-ref>

      ward dep add         <from> <type> <to>
      ward dep add         --stdin   (JSON edges or `<from> <type> <to>` lines; per-edge results)
      ward dep remove      <from> <to>

      ward config get      [dotted.key] [--workspace W] [--json]
      ward config set      <dotted.key> <value> [--workspace W] [--force]
      ward config unset    <dotted.key> [--workspace W] [--force]

      ward server start    [--timeout SECONDS] [--json]
      ward server restart  [--timeout SECONDS] [--json]
      ward server deploy   [--version vX.Y.Z] [--timeout SECONDS] [--json] [--force]
                           deploy from a GitHub Release (add --git-pull for the
                           legacy git-pull deploy).
      ward server migrate  [--json]
      ward server doctor   [--json]
      ward server version  [--json]

      ward batch           [--file PATH] [--continue-on-error]
                                   run many ward commands in ONE VM: one command per line from
                                   stdin or --file, one JSON result per line. The CLI analogue
                                   of the bulk API/MCP verbs; use it instead of shell loops.

      ward dashboard login [--json]   print a one-time browser login link

      ward workspace list
      ward workspace show  <id>

      ward message inbox   [--all | read <id> | clear | <task-id>]
      ward message send    <recipient> <body> [--subject ...] [--task bd-x] [--kind ...]
                                   (--directive is a deprecated alias for --task)
      ward message notify  [--limit N]

      ward usage show      [--by day|task|epic|workspace|repo|model|step|provider]
                                   [--since 7d|24h|<iso>] [--workspace <id>] [--limit N]
      ward usage events    [--task <task-id>] [--workspace <id>] [--step work|review]
                                   [--since ...] [--limit N]

      ward loop analyze    [--since 7d|24h|<iso>] [--until <iso>] [--limit N]
                                   [--workspace <id>] [--propose] [--discover] [--difficulty-feed] [--competence-feed] [--json]
      ward loop pending    [--state proposed|hypothesis|...] [--kind ...]
                                   [--workspace <id>] [--limit N] [--json]
      ward loop diff       <id>
      ward loop apply      <id> | all [--state proposed]
      ward loop reject     <id> [--reason "..."]

      ward trust show      [<provider/model>] [--json]   tiers, records, recent events, proposals
      ward trust promote   <provider/model> --to <tier> --reason "..."
                                   operator only: mints proof over the operator socket
      ward trust confirm   <provider/model>              let an automatic suspension stand
      ward trust dismiss   <provider/model> --reason "..."   a false positive: the tier returns

      ward settings get    [key] [--json]          install-wide settings (not workspace config)
      ward settings set    <key> <value>
      ward settings unset  <key>
      ward settings schema [--json]

      ward scheduler pause|resume|status
      ward scheduler wait  [--timeout SECS] [--interval SECS]
      ward node add     [--name N] [--label k=v ...] [--max-workers N] [--ttl 15m] [--token-file PATH]
                        mint a join token: prints the one-liner for the new node and,
                        separately, the token (terminal or --token-file only)
      ward node list|show <name|id>|events <name|id>
      ward node set <name|id> [--name N] [--label k=v ...] [--max-workers N|none]
                    [--workspace ID ...] [--allow-unenforced-network | --no-allow-unenforced-network]

      ward provider pause <provider|account-ref> [--reason TEXT] [--stop-running]
      ward provider resume <provider|account-ref>
      ward provider list

      ward quota           [--workspace <id|name>] [--json]

      ward preflip-gate    [--json]
                                   §6.3's coverage-shadow rollout gate: may
                                   `merge.coverage_enabled` be flipped?

      ward memory pending  [--state pending|rejected] [--json]   shared-memory promotion queue (operator only)
      ward memory diff     <id>
      ward memory apply    <id> [--overwrite]
      ward memory reject   <id> --reason "..."
      ward memory quarantine
      ward memory restore  <name> [--reanchor]
      ward memory distill  <session-id> [--max-bytes N] [--from-turn N] [--max-candidates N]
                                   [--max-cost-usd X]

      ward alert list      [--workspace <id|name>] [--kind <k>] [--json]
      ward breaker list    [--workspace <id|name>] [--kind <k>] [--open] [--json]
      ward breaker reset   <signature> | --all [--kind <k>] [--json]

      ward preview start   <ticket> [--repo R] [--no-wait] [--timeout SECS]
                                   run the ticket's checkout as a live app on its own
                                   port (worker.repos.<repo>.preview); prints the URL
      ward preview stop    <ticket> [--repo R]
      ward preview list    [--workspace <id|name>] [--json]
      ward preview show    <ticket> [--repo R] [--json]
      ward preview logs    <ticket> [-f] [--lines N] [--repo R]

      ward grok-token                          a grok worker's GROK_AUTH_PROVIDER_COMMAND:
                                   prints {"access_token","expires_in"} from the server

      ward image list      [--json]            worker images (podman backend) + base digest pins
      ward image build     <repo> [--workspace <id|name>] [--json]
                                   build <repo>'s image from its DEFAULT BRANCH
      ward image refresh   [--json]            re-pin base images now, then prune
      ward image prune     [--json]

      ward install cli     [--json]
      ward install service [--system] [--uninstall] [--json]

      ward mcp token mint  --tier coordinator [--workspace <id>] [--ttl <seconds>] [--json]
      ward mcp token verify <token> [--json]

      ward session list                        works with the server stopped (§4.7):
                                                reads systemd + tmux directly, never HTTP
      ward session attach <id> [--read-only]

  ## Meta commands (no resource)

      ward prime                Mission briefing — run at the start of a session
      ward where                Resolve the active workspace / paths
      ward init [path] [--force]
      ward self-update          [--version vX.Y.Z] [--json] [--force]
                                download and atomically replace ~/.local/bin/ward
                                (plus the wm symlink and arb shim) from the latest
                                GitHub Release (or --version).
                                alias: ward upgrade
      ward version
      ward help

  ## Global flags

      --json               Emit machine-readable JSON (default is human-readable text)
      -w, --workspace <n>  Target workspace by name or id; overrides WARDMAST_WORKSPACE
      -h, --help           Show usage
      --allow-fanout, --force
                           Override the refusal when too many `ward` VMs already run

  ## Env

      WARDMAST_HOST       Phoenix base URL (default http://127.0.0.1:4848; falls back to ARB_HOST)
      ARB_FANOUT_WARN / ARB_FANOUT_MAX
                          Fan-out guard thresholds (default 16 / 64 other running `ward` VMs);
                          ARB_ALLOW_FANOUT=1 lifts the refusal
      WARDMAST_WORKSPACE  Workspace name or id (unset: "default", else the sole workspace; falls back to ARB_WORKSPACE); overridden by -w / --workspace
  """

  def main(argv) do
    # Start :req's transitive applications. The escript bundles them but does
    # not auto-start. Without this, Req.get crashes with :finch not started.
    {:ok, _} = Application.ensure_all_started(:req)

    {allow_fanout?, argv} = take_allow_fanout(argv)
    if argv != [], do: WardmastCli.FanOut.enforce!(allow_fanout?)
    run(argv)
  end

  # `--allow-fanout` is stripped everywhere. `--force` also lifts the refusal; it is
  # stripped only when leading (`arb --force ticket show ...`) so subcommands with
  # their own `--force` (e.g. `ticket claim --force`) still receive it.
  defp take_allow_fanout(argv) do
    {leading, rest} = Enum.split_while(argv, &String.starts_with?(&1, "-"))
    {forced, leading} = Enum.split_with(leading, &(&1 == "--force"))
    argv = leading ++ rest
    allow? = forced != [] or "--allow-fanout" in argv or "--force" in argv

    {allow?, Enum.reject(argv, &(&1 == "--allow-fanout"))}
  end

  @doc """
  Run one `arb` command line (without the fan-out guard). `arb batch` calls this
  for each line so the whole batch is one VM and one guard check.
  """
  def run(argv) do
    # Strip -w / --workspace from the full argv before splitting into cmd/rest,
    # so the flag works at any position (including before the subcommand).
    {flag, workspace, argv} = extract_workspace_flag(argv)

    case argv do
      [] ->
        reject_flag!(flag, "ward")
        usage_and_exit(0)

      ["help" | rest] ->
        reject_flag!(flag, "ward help")
        help(rest)

      [h] when h in ["-h", "--help"] ->
        reject_flag!(flag, "ward help")
        usage_and_exit(0)

      [v] when v in ["-v", "--version"] ->
        reject_flag!(flag, "ward version")
        IO.puts("ward #{WardmastCli.Version.app_version()}")

      [cmd | rest] ->
        dispatch(cmd, rest, flag, workspace)
    end
  end

  # `arb node set --workspace W` (repeatable, or `none`) is the node's own pin
  # switch, not the global workspace selector: leave it for node.ex to parse.
  # Only the long form is the pin; `-w` stays global everywhere.
  defp extract_workspace_flag(["node", "set" | _] = argv) do
    {flag, name, rest} =
      WardmastCli.Workspace.extract_flag(Enum.map(argv, &protect_pin/1))

    {flag, name, Enum.map(rest, &unprotect_pin/1)}
  end

  defp extract_workspace_flag(argv), do: WardmastCli.Workspace.extract_flag(argv)

  defp protect_pin("--workspace"), do: {:pin, "--workspace"}
  defp protect_pin("--workspace=" <> _ = a), do: {:pin, a}
  defp protect_pin(a), do: a
  defp unprotect_pin({:pin, a}), do: a
  defp unprotect_pin(a), do: a

  # `-w` means nothing to help/version/the bare usage screen: refuse it rather
  # than run the command and ignore it.
  defp reject_flag!(nil, _verb), do: :ok

  defp reject_flag!(flag, verb),
    do: WardmastCli.Output.die("unknown option #{flag_label(flag)} for #{verb}")

  defp dispatch(cmd, args, flag, ws_val) do
    # A `--workspace <name|id>` / `-w` flag anywhere in the invocation overrides
    # the active workspace, exactly as `ARB_WORKSPACE` does. Strip it centrally —
    # before any subcommand's own `OptionParser` runs — and seed the env so every
    # subcommand honors it uniformly, without each declaring the switch.
    {extra_flag, extra_name, args} = extract_workspace_flag([cmd | args])
    args = tl(args)
    flag = flag || extra_flag
    ws_val = ws_val || extra_name

    dispatch_resolved(cmd, args, flag, ws_val)
  end

  defp dispatch_resolved(cmd, args, flag, ws_val) do
    case WardmastCli.AliasResolver.resolve(cmd) do
      {:ok, canonical} ->
        dispatch_known(canonical, args, flag, ws_val)

      {:unknown, suggestions} ->
        dispatch_legacy_or_unknown(cmd, args, suggestions, flag, ws_val)
    end
  end

  # An old flat command? Run its new form and point the user at it.
  defp dispatch_legacy_or_unknown(cmd, args, suggestions, flag, ws_val) do
    case legacy_redirect(cmd, args) do
      {:ok, canonical, new_args, new_form} ->
        case WardmastCli.Verbs.fetch(cmd) do
          {:ok, entry} -> check_workspace_guard!(entry, flag, ws_val)
          _ -> :ok
        end

        IO.puts(
          :stderr,
          "ward: note: `ward #{cmd}` is now `ward #{new_form}` — running it for you."
        )

        dispatch_known(canonical, new_args, flag, ws_val)

      :none ->
        IO.puts(:stderr, "ward: unknown command: #{cmd}")

        if suggestions != [] do
          IO.puts(:stderr, "Did you mean: #{Enum.join(suggestions, ", ")}?")
        end

        IO.puts(:stderr, "Run `ward help` for usage.")
        WardmastCli.Output.halt(2)
    end
  end

  # `arb update` was dual-mode: an id edits a ticket, a bare/flag-first call
  # deploys. Split it across the two new homes.
  defp legacy_redirect("update", args) do
    if deploy_invocation?(args) do
      {:ok, "server", ["deploy" | args], "server deploy"}
    else
      {:ok, "ticket", ["update" | args], "ticket update"}
    end
  end

  defp legacy_redirect(cmd, args) do
    case WardmastCli.Verbs.fetch(cmd) do
      {:ok, %{kind: :legacy} = entry} ->
        {:ok, entry.redirect_to, entry.prefix ++ args, WardmastCli.Verbs.new_form(entry)}

      _ ->
        :none
    end
  end

  # A bare verb, or one whose first token is a flag, is a deploy. The moment a
  # positional appears (the ticket id) it's an edit.
  defp deploy_invocation?([]), do: true
  defp deploy_invocation?([first | _]), do: String.starts_with?(first, "-")

  # bd-4jojpw: `issue` was renamed `ticket`. The old resource name keeps working
  # for one release, with a single note on stderr so `--json` stdout stays clean.
  defp dispatch_known("issue", args, flag, ws_val) do
    {:ok, entry} = WardmastCli.Verbs.fetch("issue")
    check_workspace_guard!(entry, flag, ws_val)
    WardmastCli.Workspace.put_selected(ws_val)

    IO.puts(
      :stderr,
      "ward: note: `ward issue` is deprecated; use `ward ticket` (same subcommands)."
    )

    run_entry(entry, args)
  end

  defp dispatch_known(name, args, flag, ws_val) do
    {:ok, entry} = WardmastCli.Verbs.fetch(name)
    check_workspace_guard!(entry, flag, ws_val)
    WardmastCli.Workspace.put_selected(ws_val)
    run_entry(entry, args)
  end

  defp check_workspace_guard!(entry, flag, ws_val) do
    cond do
      flag != nil and entry.workspace == :none ->
        WardmastCli.Output.die("unknown option #{flag_label(flag)} for ward #{entry.name}")

      flag != nil and is_nil(ws_val) ->
        WardmastCli.Output.die(
          "option #{flag_label(flag)} for ward #{entry.name} requires a value"
        )

      true ->
        :ok
    end
  end

  defp flag_label(flag) when is_binary(flag) do
    cond do
      String.starts_with?(flag, "--workspace=") -> "--workspace"
      String.starts_with?(flag, "-w=") -> "-w"
      true -> flag
    end
  end

  defp flag_label(_), do: "--workspace"

  defp run_entry(entry, args) do
    case entry.handler do
      __MODULE__ -> usage_and_exit(0)
      handler -> handler.run(WardmastCli.Verbs.handler_args(entry, args))
    end
  end

  # Terminates the VM via `Output.halt/1` on every clause — spelled out so
  # dialyzer does not report it as an accidental "no local return".
  @spec help(term()) :: no_return()
  defp help(_), do: usage_and_exit(0)

  # Terminates the VM via `Output.halt/1` on every clause — spelled out so
  # dialyzer does not report it as an accidental "no local return".
  @spec usage_and_exit(non_neg_integer()) :: no_return()
  defp usage_and_exit(code) do
    IO.puts(@moduledoc)
    WardmastCli.Output.halt(code)
  end
end

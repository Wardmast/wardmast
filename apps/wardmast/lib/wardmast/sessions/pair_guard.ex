defmodule Wardmast.Sessions.PairGuard do
  @moduledoc """
  The pair session's write scope (bd-7p6a9o): it may edit only its ticket's
  worktree and push only its ticket's branch — never the default branch, never
  the primary checkout.

  A pair session inherits every guard an interactive session already has
  (`Wardmast.Agents.SecurityPolicy.interactive_session/0` and
  `Wardmast.Agents.Claude.ConfigDir.Interactive`'s checkout deny), and adds two
  layers of its own:

    * **`deny_rules/1`** — Claude Code permission rules merged into the
      session's `settings.json`: pushes to the default branch in the spellings
      an agent reaches for, the ways round the push guard below
      (`--no-verify`, overriding `core.hooksPath`), opening or merging a PR
      itself (Done does that), and git or edits aimed at the primary checkout.
      Prompt-layer rules: a determined variant can phrase around a prefix, so
      they are the first layer, not the last.
    * **The push guard** — a `pre-push` hook (`install_hooks/2`) reached
      through `core.hooksPath`, set by `git_env/1` in the session's own
      environment (`GIT_CONFIG_COUNT`/`KEY`/`VALUE`, git's documented
      command-line-scope config). Every git the session runs carries it; git
      anywhere else — the primary checkout, a worker in a sibling worktree,
      the server's own push at Done — never sees it, because nothing is
      written to the repo's shared `.git/config` or `hooks/`. It refuses any
      remote ref but `refs/heads/<ticket branch>`, and refuses deleting that
      one.

  Setting `core.hooksPath` replaces the repo's own hooks for the session, so
  the repo's hooks are wrapped by stubs that run them — the session's commits
  and pushes still go through the repo's own pre-commit and pre-push. The
  hooks git fires once per command are always wrapped, so one the repo
  installs mid-session still runs; the two it fires on every ref or index
  update are wrapped only when the repo already has them, since a stub there
  would fork a shell on every `git status`.

  The repo's hooks dir comes from `Wardmast.Worker.Worktree.hooks_dir/1`, the
  guarded host-side git every worker checkout is read through (bd-6t7u81): a
  checkout whose `.git` a worker replaced yields no hooks dir, so the session
  never wraps hooks a worker planted. This module spawns nothing itself.
  """

  alias Wardmast.Worker.Worktree

  # Client-side hooks git fires at most once per command: always wrapped.
  @wrapped_hooks ~w(
    applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit
    prepare-commit-msg commit-msg post-commit pre-rebase post-checkout
    post-merge post-rewrite pre-auto-gc sendemail-validate
  )

  # Hooks git fires on every ref or index update: wrapped only if present.
  @hot_hooks ~w(reference-transaction post-index-change)

  @hook_mode 0o755

  @typedoc "What the guard is drawn around."
  @type ctx :: %{
          optional(:branch) => String.t() | nil,
          optional(:target_branch) => String.t() | nil,
          optional(:primary_checkout) => String.t() | nil,
          optional(:worktree) => String.t() | nil
        }

  @doc """
  The pair-specific Claude deny rules for a session on `ctx.branch`, based on
  `ctx.target_branch` (default `"main"`), kept off `ctx.primary_checkout`
  (none when it is `nil`: an unresolved checkout yields no rule rather than an
  invented one).

  The checkout's `Edit` rule uses Claude Code's absolute form, `//<path>`: a
  single leading `/` is read relative to the settings file.
  """
  @spec deny_rules(ctx()) :: [String.t()]
  def deny_rules(ctx) when is_map(ctx) do
    target = present(Map.get(ctx, :target_branch)) || "main"

    Enum.uniq(
      push_rules(target) ++ bypass_rules() ++ checkout_rules(Map.get(ctx, :primary_checkout))
    )
  end

  @doc """
  The environment that points the session's git at the hooks in `hooks_dir`:
  `core.hooksPath` in command-line scope, which outranks every config file.
  """
  @spec git_env(String.t()) :: [{String.t(), String.t()}]
  def git_env(hooks_dir) when is_binary(hooks_dir) do
    [
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "core.hooksPath"},
      {"GIT_CONFIG_VALUE_0", hooks_dir}
    ]
  end

  @doc """
  Write the session's hooks into `hooks_dir`: the `pre-push` guard for
  `ctx.branch`, and the stubs that run `ctx.worktree`'s repo's own hooks.
  Idempotent — every file is rewritten. `{:error, reason}` when the branch is
  missing or a file cannot be written: a pair session must not launch with a
  guard that is not there.
  """
  @spec install_hooks(String.t(), ctx()) :: :ok | {:error, term()}
  def install_hooks(hooks_dir, ctx) when is_binary(hooks_dir) and is_map(ctx) do
    case present(Map.get(ctx, :branch)) do
      nil ->
        {:error, :no_branch}

      branch ->
        # The repo's own hooks dir, resolved now — without the session's
        # override — so the stubs can run it later. `nil` for no worktree.
        original = Worktree.hooks_dir(Map.get(ctx, :worktree))

        with :ok <- File.mkdir_p(hooks_dir),
             :ok <- write_hook(hooks_dir, "pre-push", pre_push(branch, original)) do
          write_delegates(hooks_dir, original)
        end
    end
  end

  defp write_delegates(hooks_dir, original) do
    original
    |> wrapped_hooks()
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case write_hook(hooks_dir, name, delegate(name, original)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # ---- rules --------------------------------------------------------------

  defp push_rules(target) do
    for spelling <- [
          "git push origin #{target}",
          "git push origin HEAD:#{target}",
          "git push origin HEAD:refs/heads/#{target}",
          "git push origin +#{target}",
          "git push origin +HEAD:#{target}",
          "git push -u origin #{target}",
          "git push --set-upstream origin #{target}",
          "git push origin --delete",
          "git push --delete",
          "git push --mirror",
          "git push --all",
          "git push --tags"
        ],
        do: "Bash(#{spelling}:*)"
  end

  defp bypass_rules do
    [
      "Bash(git push --no-verify:*)",
      "Bash(git -c core.hooksPath:*)",
      "Bash(git -c core.hookspath:*)",
      "Bash(git config core.hooksPath:*)",
      "Bash(git config --local core.hooksPath:*)",
      "Bash(git config --global core.hooksPath:*)",
      "Bash(GIT_CONFIG_COUNT=:*)",
      "Bash(unset GIT_CONFIG:*)",
      "Bash(env -u GIT_CONFIG:*)",
      "Bash(gh pr create:*)",
      "Bash(gh pr merge:*)",
      "Bash(glab mr create:*)",
      "Bash(glab mr merge:*)"
    ]
  end

  defp checkout_rules(checkout) do
    case present(checkout) do
      nil ->
        []

      path ->
        root = path |> Path.expand() |> String.trim_trailing("/")
        ["Edit(/#{root}/**)", "Bash(git -C #{root}:*)", "Bash(cd #{root}:*)"]
    end
  end

  # ---- hooks --------------------------------------------------------------

  # No repo hooks dir at all: nothing to run, so nothing to wrap.
  defp wrapped_hooks(nil), do: []

  defp wrapped_hooks(dir) do
    @wrapped_hooks ++
      Enum.filter(@hot_hooks, fn name ->
        path = Path.join(dir, name)
        File.regular?(path) and executable?(path)
      end)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp pre_push(branch, original) do
    """
    #!/bin/sh
    # Generated by Wardmast.Sessions.PairGuard (bd-7p6a9o) for a pair session;
    # rewritten on every provision. This session may push only its ticket's
    # branch. Reached through the session's own core.hooksPath (GIT_CONFIG_*):
    # git outside the session never runs it.
    allowed=#{sh_quote("refs/heads/" <> branch)}
    input=$(cat)
    refused=0
    while read -r local_ref local_sha remote_ref remote_sha; do
      [ -n "$remote_ref" ] || continue
      if [ "$remote_ref" != "$allowed" ]; then
        echo "wardmast: this pair session may push only $allowed; refusing $remote_ref" >&2
        refused=1
      else
        case "$local_sha" in
          *[!0]*) ;;
          *)
            echo "wardmast: this pair session may not delete $allowed" >&2
            refused=1
            ;;
        esac
      fi
    done <<WARDMAST_PUSH_REFS
    $input
    WARDMAST_PUSH_REFS
    [ "$refused" -eq 0 ] || exit 1
    #{chain_pre_push(original)}
    """
  end

  defp chain_pre_push(nil), do: "exit 0"

  defp chain_pre_push(original) do
    """
    orig=#{sh_quote(Path.join(original, "pre-push"))}
    if [ -x "$orig" ]; then
      if [ -n "$input" ]; then printf '%s\\n' "$input"; fi | "$orig" "$@"
      exit $?
    fi
    exit 0
    """
  end

  defp delegate(name, original) do
    """
    #!/bin/sh
    # Generated by Wardmast.Sessions.PairGuard (bd-7p6a9o): the session's
    # core.hooksPath replaces the repo's hooks, so this runs the repo's own.
    orig=#{sh_quote(Path.join(original, name))}
    [ -x "$orig" ] || exit 0
    exec "$orig" "$@"
    """
  end

  defp write_hook(dir, name, content) do
    path = Path.join(dir, name)

    with :ok <- File.write(path, content),
         :ok <- File.chmod(path, @hook_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:hook_write_failed, path, reason}}
    end
  end

  defp sh_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end

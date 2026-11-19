defmodule Wardmast.Doctrine do
  @moduledoc """
  The bundled, installation-agnostic coordinator doctrine (bd-6dpdwm).

  One source of truth: `apps/wardmast/priv/doctrine/<section>.md.eex`. Each
  file is a self-contained Markdown section, compiled into this module at
  build time. Two consumers render the same files:

    * `Wardmast.Sessions.Instructions` — the per-session `CLAUDE.md` /
      `GEMINI.md`, and
    * `WardmastCli.Cmd.Init` — the `AGENTS.md` that `arb init` scaffolds.
      The escript cannot depend on this app, so it embeds the very same files
      at its own compile time (see its `@doctrine_dir`) rather than keeping a
      second copy of the text.

  ## Assigns

  A section reads only what it needs, via `assigns[:key]`, so a caller passes
  a map with whichever of these apply:

    * `:can_dispatch` — whether the reader may dispatch workers (`role`,
      `research`, `commands`); absent means `false`.
    * `:domain_prefix` — the workspace's ticket prefix for examples; absent
      renders the placeholder `<prefix>` (`concepts`, `commands`).
    * `:primary_checkout` — the live source tree to warn about (`checkout`).
      `nil`/absent renders the "repository work, if the operator asks"
      variant instead of the warning; **no path is ever invented**.

  ## Session instruction sets

  `priv/doctrine/sessions/<name>.md.eex` holds the instruction sets of the
  session kinds that are *not* coordinators, rendered **instead of** the
  doctrine above, never alongside it: `pair` (bd-7p6a9o) is a pair session's
  — collaborate, explain changes, ask before large rewrites, stay inside the
  ticket's acceptance criteria. They live in their own directory so that the
  coordinator doctrine stays exactly `priv/doctrine/*.md.eex` for both
  consumers: `sections/0` and `arb init`'s glob never see them, and
  `session_sets/0` names them. `render/2` renders either kind.

  ## Installation-agnostic

  The files ship to every installation. `Wardmast.DoctrineTest` fails if any
  of them carries a denylisted string (installation or host names, home
  paths, personal names). Anything installation-specific has to come in as an
  assign, never as text.
  """

  require EEx

  @dir Path.expand("../../priv/doctrine", __DIR__)
  @sessions_dir Path.join(@dir, "sessions")

  # The directories themselves, not only the files found in them: a file
  # *added* later changes its directory's mtime, which is what makes Mix
  # recompile this module to pick it up.
  @external_resource @dir
  @external_resource @sessions_dir

  bundled = fn dir ->
    dir
    |> Path.join("*.md.eex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      {path |> Path.basename(".md.eex") |> String.to_atom(), path}
    end)
  end

  @sections bundled.(@dir)
  @session_sets bundled.(@sessions_dir)

  for {name, _path} <- @session_sets, Keyword.has_key?(@sections, name) do
    raise "session instruction set #{name} shares its name with a coordinator doctrine section"
  end

  for {name, path} <- @sections ++ @session_sets do
    @external_resource path
    EEx.function_from_file(:defp, :"render_#{name}", path, [:assigns])
  end

  @doc """
  The names of every bundled coordinator doctrine section — what a
  coordinator session's `CLAUDE.md` and `arb init`'s `AGENTS.md` embed in
  full.
  """
  @spec sections() :: [atom()]
  def sections, do: Enum.map(@sections, &elem(&1, 0))

  @doc """
  The names of the bundled session instruction sets (`priv/doctrine/sessions/`),
  which a non-coordinator session kind renders instead of the coordinator
  doctrine.
  """
  @spec session_sets() :: [atom()]
  def session_sets, do: Enum.map(@session_sets, &elem(&1, 0))

  @doc """
  Render one bundled section or session instruction set with `assigns` (see
  the moduledoc). Raises `FunctionClauseError` for an unknown name.
  """
  @spec render(atom(), map() | keyword()) :: String.t()
  for {name, _path} <- @sections ++ @session_sets do
    # sobelow_skip ["DOS.BinToAtom"]
    def render(unquote(name), assigns) do
      unquote(:"render_#{name}")(Map.new(assigns)) |> String.trim()
    end
  end
end

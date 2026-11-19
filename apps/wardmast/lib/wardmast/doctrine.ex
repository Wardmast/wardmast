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

  ## Installation-agnostic

  The files ship to every installation. `Wardmast.DoctrineTest` fails if any
  of them carries a denylisted string (installation or host names, home
  paths, personal names). Anything installation-specific has to come in as an
  assign, never as text.
  """

  require EEx

  @dir Path.expand("../../priv/doctrine", __DIR__)

  @sections @dir
            |> Path.join("*.md.eex")
            |> Path.wildcard()
            |> Enum.sort()
            |> Enum.map(fn path ->
              {path |> Path.basename(".md.eex") |> String.to_atom(), path}
            end)

  for {name, path} <- @sections do
    @external_resource path
    EEx.function_from_file(:defp, :"render_#{name}", path, [:assigns])
  end

  @doc "The names of every bundled section."
  @spec sections() :: [atom()]
  def sections, do: Enum.map(@sections, &elem(&1, 0))

  @doc """
  Render one bundled section with `assigns` (see the moduledoc). Raises
  `FunctionClauseError` for an unknown section.
  """
  @spec render(atom(), map() | keyword()) :: String.t()
  for {name, _path} <- @sections do
    # sobelow_skip ["DOS.BinToAtom"]
    def render(unquote(name), assigns) do
      unquote(:"render_#{name}")(Map.new(assigns)) |> String.trim()
    end
  end
end

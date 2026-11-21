defmodule Wardmast.DataHomeGuardTest do
  # bd-88syir: the data home is decided in exactly one place
  # (`Wardmast.Env.data_home/0`). Ten private copies, each with its own
  # precedence, is how a release server ended up reading one home and the CLI
  # another. This test keeps a new copy from creeping back in, and pins the
  # shell twin in `rel/env.sh.eex` to the Elixir resolver.
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)
  @resolver "apps/wardmast_release_env/lib/wardmast/env.ex"

  # `<dir>/.wardmast` built from some *other* base is not the operator's data
  # home; each entry says why it is allowed to name the directory.
  @allowed %{
    "apps/wardmast_cli/lib/wardmast_cli/cmd/install_service/launchd.ex" =>
      "a daemon's data home is the SERVICE user's home, not the installing user's"
  }

  defp source_files do
    (Path.wildcard(Path.join(@root, "apps/*/lib/**/*.ex")) ++
       Path.wildcard(Path.join(@root, "config/**/*.exs")))
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.reject(&(&1 == @resolver))
  end

  # A string literal that spells the data-home directory by hand. Docs and
  # comments are exempt (comments are not in the AST; `@doc`-family attributes
  # are skipped below).
  defp data_home_literal?(s) when is_binary(s) do
    s in [".wardmast", "/.wardmast"] or String.starts_with?(s, "~/.wardmast")
  end

  @doc_attrs [:doc, :moduledoc, :typedoc]

  defp literals(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{attr, _, _}]}, acc when attr in @doc_attrs -> {:skip, acc}
        s, acc when is_binary(s) -> {s, if(data_home_literal?(s), do: [s | acc], else: acc)}
        node, acc -> {node, acc}
      end)

    acc
  end

  test "no module hand-rolls the data home outside Wardmast.Env.data_home/0" do
    offenders =
      for file <- source_files(),
          not Map.has_key?(@allowed, file),
          ast = file |> then(&Path.join(@root, &1)) |> File.read!() |> Code.string_to_quoted!(),
          found = literals(ast),
          found != [],
          do: {file, Enum.uniq(found)}

    assert offenders == [],
           """
           These files spell the data home (`~/.wardmast`) themselves. Call
           `Wardmast.Env.data_home/0` instead (bd-88syir):

           #{Enum.map_join(offenders, "\n", fn {f, l} -> "  #{f}: #{inspect(l)}" end)}
           """
  end

  test "every allow-list entry still needs its exemption" do
    for {file, _why} <- @allowed do
      ast = @root |> Path.join(file) |> File.read!() |> Code.string_to_quoted!()

      assert literals(ast) != [],
             "#{file} no longer hand-rolls the data home; drop it from @allowed"
    end
  end

  describe "rel/env.sh.eex resolves the same data home as Wardmast.Env.data_home/0" do
    @env_sh Path.join(@root, "rel/env.sh.eex")

    defp shell_data_home(env) do
      [line] =
        @env_sh
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "arbiter_data_home="))

      {out, 0} =
        System.cmd("sh", ["-c", String.trim(line) <> "\nprintf %s \"$arbiter_data_home\""],
          env: env
        )

      out
    end

    defp elixir_data_home(env) do
      prior = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)
      prior_cfg = Application.fetch_env(:wardmast, :data_dir)

      try do
        Application.delete_env(:wardmast, :data_dir)

        Enum.each(env, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)

        Wardmast.Env.data_home()
      after
        Enum.each(prior, fn {k, v} ->
          if v, do: System.put_env(k, v), else: System.delete_env(k)
        end)

        with {:ok, v} <- prior_cfg, do: Application.put_env(:wardmast, :data_dir, v)
      end
    end

    # The two use the same variables, in the same order, and treat an empty
    # value as unset. (The shell has no `ARBITER_DATA_HOME` and does not
    # expand `~`; neither is exercised here.)
    test "same answer for every combination of the variables" do
      home = System.user_home!()

      for new <- [nil, "", "/srv/new"],
          legacy <- [nil, "", "/srv/legacy"] do
        env = [
          {"WARDMAST_DATA_HOME", new},
          {"ARB_DATA_HOME", legacy},
          {"HOME", home}
        ]

        sh = shell_data_home(env)
        ex = elixir_data_home(Enum.reject(env, fn {k, _} -> k == "HOME" end))

        assert sh == ex,
               "env.sh.eex and Wardmast.Env.data_home/0 disagree for #{inspect(env)}: " <>
                 "sh=#{inspect(sh)} elixir=#{inspect(ex)}"
      end
    end
  end
end

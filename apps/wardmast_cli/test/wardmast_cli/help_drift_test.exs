defmodule WardmastCli.HelpDriftTest do
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Main
  alias WardmastCli.Verbs

  test "`arb help` lists every non-deprecated registry verb" do
    {out, _err, 0} = capture(fn -> Main.main(["help"]) end)

    missing =
      for %{name: name, kind: kind, deprecated: false} <- Verbs.all(),
          kind in [:resource, :shortcut],
          not Regex.match?(~r/\barb #{Regex.escape(name)}\b/, out),
          do: name

    assert missing == []
  end

  test "`arb ticket create --help` documents every accepted flag" do
    {out, _err, 0} = capture(fn -> Main.main(["ticket", "create", "--help"]) end)

    missing =
      for {switch, _type} <- WardmastCli.Cmd.Create.switches(),
          flag = "--" <> String.replace(to_string(switch), "_", "-"),
          not String.contains?(out, flag),
          do: flag

    assert missing == []
  end
end

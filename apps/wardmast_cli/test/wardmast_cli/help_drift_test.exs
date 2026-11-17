defmodule WardmastCli.HelpDriftTest do
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Main
  alias WardmastCli.Verbs

  test "`ward --help` lists every non-deprecated registry verb and shows `ward` throughout" do
    {out, _err, 0} = capture(fn -> Main.main(["--help"]) end)

    missing =
      for %{name: name, kind: kind, deprecated: false} <- Verbs.all(),
          kind in [:resource, :shortcut],
          not Regex.match?(~r/\bward #{Regex.escape(name)}\b/, out),
          do: name

    assert missing == []
    refute Regex.match?(~r/^\s+arb\s+\w/m, out)
    assert out =~ "WARDMAST_HOST"
    assert out =~ "WARDMAST_WORKSPACE"
    assert out =~ "wm"
  end

  test "`ward ticket create --help` (and `ward issue create --help`) documents every accepted flag and uses `ward` in the rubric" do
    {out, _err, 0} = capture(fn -> Main.main(["ticket", "create", "--help"]) end)

    missing =
      for {switch, _type} <- WardmastCli.Cmd.Create.switches(),
          flag = "--" <> String.replace(to_string(switch), "_", "-"),
          not String.contains?(out, flag),
          do: flag

    assert missing == []
    assert out =~ "ward ticket create"
    assert out =~ "WARDMAST_WORKSPACE"
    refute out =~ ~r/\barb (ticket|create|config|dispatch|claim)\b/

    {issue_out, issue_err, 0} = capture(fn -> Main.main(["issue", "create", "--help"]) end)
    assert issue_out == out
    assert issue_err =~ "deprecated"
  end
end

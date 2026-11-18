defmodule Wardmast.Mergers.ForgeCliTest do
  use ExUnit.Case, async: true

  alias Wardmast.Mergers.ForgeCli
  alias Wardmast.Tasks.Workspace

  test "forge/2 is :gitlab only for a gitlab strategy" do
    gl = %Workspace{config: %{"merge" => %{"strategy" => "gitlab"}}}
    gh = %Workspace{config: %{"merge" => %{"strategy" => "github"}}}
    assert ForgeCli.forge(gl, nil) == :gitlab
    assert ForgeCli.forge(gh, nil) == :github
    assert ForgeCli.forge(nil, nil) == :github
  end

  test "forge_from_ref/1 and ref_number/1 understand both ref shapes" do
    assert ForgeCli.forge_from_ref("grp/proj!7") == :gitlab
    assert ForgeCli.forge_from_ref("!7") == :gitlab
    assert ForgeCli.forge_from_ref("owner/repo#7") == :github
    assert ForgeCli.forge_from_ref("7") == :github
    assert ForgeCli.ref_number("grp/proj!7") == 7
    assert ForgeCli.ref_number("owner/repo#42") == 42
    assert ForgeCli.ref_number("nope") == nil
  end

  test "commands" do
    assert ForgeCli.checkout_cmd(:github, "42") == "gh pr checkout 42"
    assert ForgeCli.checkout_cmd(:gitlab, "grp/proj!42") == "glab mr checkout 42"
    assert ForgeCli.view_cmd(:gitlab, "!42") == "glab mr view 42"
    assert ForgeCli.reviews_cmd(:github, "42") == "gh pr view 42 --json reviews,reviewComments"
    assert ForgeCli.reviews_cmd(:gitlab, "42") == "glab mr view 42 --comments"
    assert ForgeCli.template_hint(:gitlab) =~ ".gitlab/merge_request_templates/Default.md"

    assert ForgeCli.job_trace_url("https://gl.example/g/p/-/jobs/9") ==
             "https://gl.example/g/p/-/jobs/9/raw"
  end
end

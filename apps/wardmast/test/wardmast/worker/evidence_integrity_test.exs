defmodule Wardmast.Worker.EvidenceIntegrityTest do
  @moduledoc """
  bd-80talz: the detection rule that sends a ReviewGate rejection to the
  coordinator instead of another fix round on the same provider, when the
  reviewer says the work fabricated or falsified its evidence.
  """

  use ExUnit.Case, async: true

  alias Wardmast.Worker.EvidenceIntegrity

  # The round-2 REQUEST_CHANGES the ReviewGate reviewer wrote on bd-aro53b
  # (PR #2057), verbatim from `review_gate_rounds`. The agy worker had passed a
  # standalone HTML mockup off as screenshots of the app, hosted on
  # files.catbox.moe, and swapped a true citation for an unverified one.
  @aro53b_round2 File.read!(
                   Path.expand("../../fixtures/review_findings_bd_aro53b_round2.md", __DIR__)
                 )

  describe "flagged?/1 and flagged_lines/1" do
    test "flags bd-aro53b's round-2 findings" do
      assert EvidenceIntegrity.flagged?(@aro53b_round2)

      lines = EvidenceIntegrity.flagged_lines(@aro53b_round2)
      assert Enum.any?(lines, &(&1 =~ "fabricated static mockup"))
      assert Enum.any?(lines, &(&1 =~ "reads as fabricated evidence"))
    end

    test "only returns the lines that carry the accusation" do
      lines = EvidenceIntegrity.flagged_lines(@aro53b_round2)

      refute Enum.any?(lines, &(&1 =~ "NOTICE carries the trademark"))
      refute Enum.any?(lines, &String.starts_with?(&1, "VERDICT:"))
    end

    test "the explicit reviewer tag always flags" do
      text = "VERDICT: REQUEST_CHANGES\n1. [FABRICATED-EVIDENCE] PR body: the test log was edited"
      assert EvidenceIntegrity.flagged?(text)
    end

    test "flags finding lines tagged [FABRICATED-EVIDENCE] across list, bold, and heading formats" do
      for line <- [
            "1. [FABRICATED-EVIDENCE] PR body: the test log was edited",
            "1) [FABRICATED-EVIDENCE] PR body: the test log was edited",
            "- [FABRICATED-EVIDENCE] PR body: the test log was edited",
            "* [FABRICATED-EVIDENCE] PR body: the test log was edited",
            "1. **[High]** `[FABRICATED-EVIDENCE]` PR body: the test log was edited",
            "- **Critical** — [FABRICATED-EVIDENCE] PR body: the test log was edited",
            "### 1. [FABRICATED-EVIDENCE] PR body: the test log was edited",
            "[FABRICATED-EVIDENCE] PR body: the test log was edited",
            "1. **[FABRICATED-EVIDENCE]** log was edited",
            "**[FABRICATED-EVIDENCE]** PR body: the test log was edited",
            "Finding 1: [FABRICATED-EVIDENCE] PR body: the test log was edited",
            "- **F1** [FABRICATED-EVIDENCE] PR body: the test log was edited",
            "[High] F1.2 [FABRICATED-EVIDENCE] PR body: the test log was edited"
          ] do
        assert EvidenceIntegrity.flagged?("VERDICT: REQUEST_CHANGES\n" <> line),
               "expected #{inspect(line)} to flag"
      end
    end

    test "does not flag a negated 'No `[FABRICATED-EVIDENCE]` findings' line (bd-dm5uun / vs-a4iz8r)" do
      vs_a4iz8r = """
      VERDICT: REQUEST_CHANGES
      CRITERIA:
      - [NOT MET] AC1 — `lib/vstim_web/live/chart_live.ex:42` missing guard
      Findings:
      1. **[Medium] `lib/vstim_web/live/chart_live.ex:42`** — guard nil before rendering.
      No `[FABRICATED-EVIDENCE]` findings: I reproduced the render claims in the MR description.
      VERIFICATION: FULL
      arb done
      """

      refute EvidenceIntegrity.flagged?(vs_a4iz8r)
      assert EvidenceIntegrity.flagged_lines(vs_a4iz8r) == []
    end

    test "does not flag prose or bullet lines that negate or merely quote [FABRICATED-EVIDENCE] in backticks" do
      for line <- [
            "No `[FABRICATED-EVIDENCE]` findings: I reproduced the render claims in the MR description.",
            "No [FABRICATED-EVIDENCE] findings.",
            "- No `[FABRICATED-EVIDENCE]` findings in this MR.",
            "* No [FABRICATED-EVIDENCE] issues found.",
            "There are no `[FABRICATED-EVIDENCE]` findings.",
            "I found no `[FABRICATED-EVIDENCE]` issues in the PR description.",
            "Not a `[FABRICATED-EVIDENCE]` finding — the screenshot is genuine.",
            "None of the findings are `[FABRICATED-EVIDENCE]`.",
            "Without `[FABRICATED-EVIDENCE]` findings, the gate dispatches a fix round.",
            "- [NOT MET] A review that tags a finding `[FABRICATED-EVIDENCE]` still escalates as before.",
            "The parser matches `[FABRICATED-EVIDENCE]` when it tags a finding.",
            "1. **Severity: medium** — `@tagged_finding` only allows a backtick before `[FABRICATED-EVIDENCE]`."
          ] do
        refute EvidenceIntegrity.flagged?(line),
               "expected #{inspect(line)} not to flag"
      end
    end

    test "does not flag a full review that quotes `[FABRICATED-EVIDENCE]` in backticks while discussing the parser" do
      review = """
      VERDICT: REQUEST_CHANGES
      CRITERIA:
      - [MET] A review saying "No `[FABRICATED-EVIDENCE]` findings" is not treated as fabricated evidence and gets the normal fix round.
      - [NOT MET] A review that tags a finding `[FABRICATED-EVIDENCE]` still escalates as before.
      Findings:
      1. **Severity: medium** — `apps/wardmast/lib/wardmast/worker/evidence_integrity.ex:72`: the regex only allows a backtick directly before `[FABRICATED-EVIDENCE]`.
      VERIFICATION: FULL
      arb done
      """

      refute EvidenceIntegrity.flagged?(review)
      assert EvidenceIntegrity.flagged_lines(review) == []
    end

    for phrase <- [
          "the screenshots are fabricated",
          "a falsified citation to the press kit",
          "the attribution is misrepresented as official",
          "a mockup passed off as screenshots of the app",
          "the benchmark numbers look doctored",
          "the test output in the PR body was fabricated"
        ] do
      test "flags #{inspect(phrase)}" do
        assert EvidenceIntegrity.flagged?("1. [High] PR body — " <> unquote(phrase) <> ".")
      end
    end

    for phrase <- [
          "I found no fabricated evidence; the screenshots are real captures",
          "the citation is not fabricated — it matches the Wikimedia file",
          "nothing in the PR body is falsified",
          "the test fabricates a fake Issue struct instead of inserting one",
          "use a fake adapter in the test",
          "the mock returns a fabricated pid",
          "screenshots are missing from the PR",
          # bd-94xq54 round 1, the logical sense of the word:
          "a present-tense claim about source that this PR falsifies"
        ] do
      test "does not flag #{inspect(phrase)}" do
        refute EvidenceIntegrity.flagged?(
                 "1. [Medium] lib/foo.ex:12 — " <> unquote(phrase) <> "."
               )
      end
    end

    test "nil and empty text never flag" do
      refute EvidenceIntegrity.flagged?(nil)
      refute EvidenceIntegrity.flagged?("")
      assert EvidenceIntegrity.flagged_lines(nil) == []
    end
  end

  describe "escalation_findings/2 and escalation?/1" do
    test "leads with the marker and quotes the flagged lines ahead of the payload" do
      body = EvidenceIntegrity.escalation_findings(@aro53b_round2, "FULL TRANSCRIPT")

      assert String.starts_with?(body, EvidenceIntegrity.marker())
      assert body =~ "fabricated static mockup"
      assert body =~ "FULL TRANSCRIPT"
      assert EvidenceIntegrity.escalation?(body)
    end

    # The gate already ran the rule on the reviewer's findings; anything else
    # it reports is the cap payload (thread + diff), which must not be scanned.
    test "only the gate's marker escalates, not text that merely flags" do
      refute EvidenceIntegrity.escalation?(@aro53b_round2)

      refute EvidenceIntegrity.escalation?("""
             ReviewGate escalation — not converged after 2 round(s) of review

             ### Round 1 — Implementer → Reviewer: REBUTTED
             I disagree the icon source is fabricated.

             + # A test helper that fabricates a source map for the icon fixture
             + mockup passed off as a screenshot is not acceptable evidence
             """)
    end

    test "an ordinary rejection is not" do
      refute EvidenceIntegrity.escalation?("VERDICT: REQUEST_CHANGES\n- [high] a.ex:1 nil guard")
      refute EvidenceIntegrity.escalation?(nil)
    end
  end
end

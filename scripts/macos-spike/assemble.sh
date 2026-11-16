#!/usr/bin/env bash
# Build results.md from the per-probe .result/.log files. Always exits 0.
set -u
dir="${RESULTS_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macos-spike-results}"
out="$dir/results.md"
probes="launchd abandon-pgroup keepalive peercred setsid codesign quarantine clonefile otp-static-ssl"
{
  echo "# macOS assumptions spike (bd-cq5b18)"
  echo
  echo "- runner: \`$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) $(uname -m)\`"
  echo "- run: ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-local}"
  echo "- sha: ${GITHUB_SHA:-unknown}"
  echo
  echo "## Summary"
  echo
  for p in $probes; do
    if [ -s "$dir/$p.result" ]; then
      echo "- \`$p\` — $(cat "$dir/$p.result")"
    else
      echo "- \`$p\` — INCONCLUSIVE: probe did not run (step skipped or cancelled)"
    fi
  done
  echo
  echo "## Raw output"
  for p in $probes; do
    echo
    echo "<details><summary>$p</summary>"
    echo
    echo '```'
    tail -n 200 "$dir/$p.log" 2>/dev/null
    echo '```'
    echo
    echo "</details>"
  done
} >"$out"
cat "$out"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$out" >>"$GITHUB_STEP_SUMMARY"
exit 0

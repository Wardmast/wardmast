#!/usr/bin/env bash
# Shared helpers for the macOS assumption probes (bd-cq5b18).
# Source this from a probe: `. "$(dirname "$0")/lib.sh"; probe_init <name>`.
# A probe records exactly one result via `pass`, `fail` or `inconclusive`;
# if it exits without recording one, the EXIT trap records FAIL.

RESULTS_DIR="${RESULTS_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macos-spike-results}"
mkdir -p "$RESULTS_DIR"

probe_init() {
  PROBE="$1"
  PROBE_LOG="$RESULTS_DIR/$PROBE.log"
  PROBE_RESULT="$RESULTS_DIR/$PROBE.result"
  : >"$PROBE_LOG"
  rm -f "$PROBE_RESULT"
  # Mirror everything to the raw log while still showing it in the Actions log.
  exec > >(tee -a "$PROBE_LOG") 2>&1
  trap '_probe_exit' EXIT
  echo "## probe: $PROBE  ($(date -u +%FT%TZ))"
}

_probe_exit() {
  local rc=$?
  if [ ! -s "$PROBE_RESULT" ]; then
    echo "FAIL: probe exited (rc=$rc) without recording a result" >"$PROBE_RESULT"
  fi
  # Probes never fail the step: the report carries the verdict.
  exit 0
}

_record() { printf '%s: %s\n' "$1" "$2" | tee "$PROBE_RESULT"; }
pass() { _record PASS "$*"; exit 0; }
fail() { _record FAIL "$*"; exit 0; }
inconclusive() { _record INCONCLUSIVE "$*"; exit 0; }

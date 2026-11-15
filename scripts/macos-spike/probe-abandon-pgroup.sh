#!/usr/bin/env bash
# launchd AbandonProcessGroup: a tmux server started by the job must survive
# the job being booted out when AbandonProcessGroup=true (and, as a control,
# be killed when it is false).
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init abandon-pgroup

command -v tmux >/dev/null 2>&1 || brew install tmux || inconclusive "tmux unavailable"
uid=$(id -u)
dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/abandon-spike"
mkdir -p "$dir"

run_case() { # $1 = abandon (true|false); echoes survived|killed|error
  local abandon="$1" label="dev.arbiter.spike.ab.$1.$$" sock="spike-$1-$$" domain="" d
  local plist="$dir/$label.plist"
  cat >"$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>$(command -v tmux) -L $sock new-session -d 'sleep 600'; sleep 600</string></array>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><$abandon/>
</dict></plist>
PL
  for d in "gui/$uid" "user/$uid"; do
    launchctl bootstrap "$d" "$plist" >&2 && { domain="$d"; break; }
  done
  [ -n "$domain" ] || { echo error; return; }
  sleep 3
  tmux -L "$sock" has-session >&2 2>&1 || { launchctl bootout "$domain/$label" >&2; echo error; return; }
  launchctl bootout "$domain/$label" >&2
  sleep 3
  if tmux -L "$sock" has-session >&2 2>&1; then
    echo survived
    tmux -L "$sock" kill-server >&2
  else
    echo killed
  fi
}

abandon_true=$(run_case true)
abandon_false=$(run_case false)
echo "AbandonProcessGroup=true  -> tmux $abandon_true"
echo "AbandonProcessGroup=false -> tmux $abandon_false"

case "$abandon_true/$abandon_false" in
  survived/killed) pass "tmux child survives bootout only with AbandonProcessGroup=true (control was killed)" ;;
  survived/survived) inconclusive "tmux survived in both cases (control did not die; tmux daemonises into its own session)" ;;
  killed/*) fail "tmux child was killed on bootout even with AbandonProcessGroup=true" ;;
  *) inconclusive "could not run launchd cases (true=$abandon_true false=$abandon_false)" ;;
esac

#!/usr/bin/env bash
# launchd AbandonProcessGroup: a child that stays in the job's process group
# must survive the job being booted out when AbandonProcessGroup=true, and be
# killed when AbandonProcessGroup=false (the control).
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init abandon-pgroup

uid=$(id -u)
dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/abandon-spike"
mkdir -p "$dir"

run_case() { # $1 = abandon (true|false); echoes survived|killed|error
  local abandon="$1" label="dev.arbiter.spike.ab.$1.$$" domain="" d
  local plist="$dir/$label.plist" pidfile="$dir/$label.child.pid"
  rm -f "$pidfile"
  cat >"$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>/bin/sleep 600 &lt;/dev/null &gt;/dev/null 2&gt;&amp;1 &amp; echo \$! &gt; "$pidfile"; exec /bin/sleep 600</string></array>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><$abandon/>
</dict></plist>
PL
  for d in "gui/$uid" "user/$uid"; do
    launchctl bootstrap "$d" "$plist" >&2 && { domain="$d"; break; }
  done
  [ -n "$domain" ] || { echo error; return; }
  sleep 3
  local pid=""
  [ -s "$pidfile" ] && pid=$(tr -d '[:space:]' <"$pidfile")
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    launchctl bootout "$domain/$label" >&2 2>&1 || true
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    echo error
    return
  fi
  ps -o pid=,ppid=,pgid=,comm= -p "$pid" >&2 || true
  if ! launchctl bootout "$domain/$label" >&2; then
    kill "$pid" 2>/dev/null || true
    echo error
    return
  fi
  sleep 3
  if kill -0 "$pid" 2>/dev/null; then
    echo survived
    kill "$pid" 2>/dev/null || true
  else
    echo killed
  fi
}

abandon_true=$(run_case true)
abandon_false=$(run_case false)
echo "AbandonProcessGroup=true  -> child $abandon_true"
echo "AbandonProcessGroup=false -> child $abandon_false"

case "$abandon_true/$abandon_false" in
  survived/killed)
    pass "same-pgroup child survived bootout with AbandonProcessGroup=true and was killed with false (true=$abandon_true false=$abandon_false)"
    ;;
  survived/survived)
    fail "control child was not killed on bootout with AbandonProcessGroup=false (true=$abandon_true false=$abandon_false)"
    ;;
  killed/*)
    fail "same-pgroup child was killed on bootout even with AbandonProcessGroup=true (true=$abandon_true false=$abandon_false)"
    ;;
  *)
    fail "could not verify AbandonProcessGroup behaviour (true=$abandon_true false=$abandon_false)"
    ;;
esac

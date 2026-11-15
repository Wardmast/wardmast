#!/usr/bin/env bash
# launchd KeepAlive.SuccessfulExit=false: restarted after a non-zero exit,
# NOT restarted after a clean exit 0.
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init keepalive

uid=$(id -u)
dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/keepalive-spike"
mkdir -p "$dir"

run_case() { # $1 = exit code; echoes the number of starts after 15s
  local code="$1" label="dev.arbiter.spike.ka.$1.$$" domain="" d
  local plist="$dir/$label.plist" marker="$dir/starts.$1"
  : >"$marker"
  cat >"$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>echo x &gt;&gt; $marker; exit $code</string></array>
  <key>RunAtLoad</key><true/>
  <key>ThrottleInterval</key><integer>1</integer>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PL
  for d in "gui/$uid" "user/$uid"; do
    launchctl bootstrap "$d" "$plist" >&2 && { domain="$d"; break; }
  done
  [ -n "$domain" ] || { echo -1; return; }
  sleep 15
  launchctl bootout "$domain/$label" >&2
  wc -l <"$marker" | tr -d ' '
}

clean=$(run_case 0)
crash=$(run_case 1)
echo "exit 0 -> starts=$clean (expect 1)"
echo "exit 1 -> starts=$crash (expect >1)"

if [ "$clean" -lt 0 ] || [ "$crash" -lt 0 ]; then
  inconclusive "bootstrap failed in gui and user domains"
elif [ "$clean" -eq 1 ] && [ "$crash" -gt 1 ]; then
  pass "KeepAlive.SuccessfulExit=false restarts on exit 1 (starts=$crash) and not on exit 0 (starts=$clean)"
else
  fail "unexpected restart counts: exit0=$clean exit1=$crash"
fi

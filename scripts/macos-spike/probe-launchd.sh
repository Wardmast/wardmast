#!/usr/bin/env bash
# launchd: bootstrap / kickstart -k / bootout of a throwaway LaunchAgent in the
# runner's gui/<uid> (falling back to user/<uid>) domain.
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init launchd

uid=$(id -u)
label="dev.arbiter.spike.$$"
dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/launchd-spike"
mkdir -p "$dir"
plist="$dir/$label.plist"
marker="$dir/starts"
: >"$marker"

cat >"$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>echo \$\$ &gt;&gt; $marker; exec sleep 300</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL

domain=""
for d in "gui/$uid" "user/$uid"; do
  echo "--- trying bootstrap into $d"
  if launchctl bootstrap "$d" "$plist"; then domain="$d"; break; fi
done
[ -n "$domain" ] || fail "bootstrap failed in both gui/$uid and user/$uid"

cleanup() { launchctl bootout "$domain/$label" 2>/dev/null; }
sleep 2
starts1=$(wc -l <"$marker" | tr -d ' ')
echo "starts after bootstrap: $starts1"
launchctl print "$domain/$label" | head -30

echo "--- kickstart -k"
launchctl kickstart -k "$domain/$label" || { cleanup; fail "kickstart -k failed in $domain"; }
sleep 2
starts2=$(wc -l <"$marker" | tr -d ' ')
echo "starts after kickstart -k: $starts2"

echo "--- bootout"
launchctl bootout "$domain/$label" || fail "bootout failed in $domain"
if launchctl print "$domain/$label" >/dev/null 2>&1; then
  fail "service still present after bootout"
fi

if [ "$starts1" -ge 1 ] && [ "$starts2" -gt "$starts1" ]; then
  pass "bootstrap, kickstart -k (restarted), bootout all worked in $domain"
elif [ "$starts1" -eq 0 ]; then
  inconclusive "bootstrap/bootout succeeded in $domain but the agent never ran (starts=0)"
else
  fail "kickstart -k did not restart the job in $domain (starts $starts1 -> $starts2)"
fi

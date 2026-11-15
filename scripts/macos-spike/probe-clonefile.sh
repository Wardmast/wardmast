#!/usr/bin/env bash
# `cp -c` (clonefile) on APFS: succeeds, and the clone shares blocks (cheap).
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init clonefile

work=$(mktemp -d)
echo "--- filesystem for $work"
df -T apfs "$work" 2>&1 || df "$work"
diskutil info / 2>/dev/null | grep -i "file system"
dd if=/dev/urandom of="$work/src" bs=1m count=256 2>&1
before=$(df -k "$work" | awk 'NR==2{print $4}')
if ! cp -c "$work/src" "$work/clone" 2>&1; then
  fail "cp -c failed on this volume"
fi
after=$(df -k "$work" | awk 'NR==2{print $4}')
used=$((before - after))
echo "free KiB before=$before after=$after consumed=$used (256 MiB file = 262144 KiB)"
cmp "$work/src" "$work/clone" || fail "clone content differs"
# Copy-on-write sanity: modifying the clone must not change the source.
printf 'x' | dd of="$work/clone" bs=1 count=1 conv=notrunc 2>/dev/null
if cmp -s "$work/src" "$work/clone"; then fail "clone writes leaked into source"; fi
if [ "$used" -lt 65536 ]; then
  pass "cp -c cloned 256 MiB using ~${used} KiB (copy-on-write)"
else
  inconclusive "cp -c succeeded but consumed ${used} KiB; clone may not be sharing blocks"
fi

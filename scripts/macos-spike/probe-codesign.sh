#!/usr/bin/env bash
# codesign verification of an ad-hoc signed Mach-O after `strip` and after a
# tar round-trip.
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init codesign

work=$(mktemp -d)
cat >"$work/hello.c" <<'C'
#include <stdio.h>
int main(void){puts("hi");return 0;}
C
cc -o "$work/hello" "$work/hello.c" || inconclusive "no C compiler"
codesign --force -s - "$work/hello" || fail "ad-hoc codesign failed"
codesign --verify --verbose=2 "$work/hello" || fail "fresh signature does not verify"

strip "$work/hello" 2>&1
if codesign --verify "$work/hello" 2>&1; then
  stripped=ok
else
  stripped=broken
fi
echo "after strip: $stripped"

mkdir "$work/rt"
codesign --force -s - "$work/hello"
tar -C "$work" -czf "$work/hello.tgz" hello
tar -C "$work/rt" -xzf "$work/hello.tgz"
if codesign --verify --verbose=2 "$work/rt/hello" 2>&1; then rt=ok; else rt=broken; fi
echo "after re-sign + tar round-trip: $rt"
"$work/rt/hello" || fail "round-tripped binary does not run"
# Also: does the arm64 kernel run the stripped-but-unresigned binary?
case "$stripped/$rt" in
  ok/ok) pass "signature survives strip and tar round-trip" ;;
  broken/ok) pass "strip invalidates the signature (must re-sign after strip); tar round-trip of a signed binary verifies and runs" ;;
  */broken) fail "signature does not verify after tar round-trip" ;;
esac

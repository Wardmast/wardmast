#!/usr/bin/env bash
# Offline test for package-macos.sh: runs it on any host with fake `codesign`,
# `security`, `xcrun`, `hdiutil`, `ditto` and `spctl` on PATH that log every
# call, and asserts on what the script asked them to do (ordering, flags, which
# of unsigned / signed / notarised it chose, the label on the .dmg).
#
#   desktop/scripts/test-package-macos.sh
#
# It proves the script's logic, not Apple's tools: the real signing and
# notarisation run only in the release workflow, with real credentials.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/package-macos.sh"
root="$(mktemp -d "${TMPDIR:-/tmp}/pkgmac.XXXXXX")"
trap 'rm -rf "$root"' EXIT
failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

# A fake .app: one Mach-O main binary, two Mach-O files in the bundled release,
# and a text file that must never be signed.
make_app() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/release/bin" \
    "$app/Contents/Resources/release/erts/bin" "$app/Contents/Resources/release/lib"
  printf '\xcf\xfa\xed\xfe....' >"$app/Contents/MacOS/arbiter-desktop"
  printf '\xcf\xfa\xed\xfe....' >"$app/Contents/Resources/release/erts/bin/beam.smp"
  printf '\xcf\xfa\xed\xfe....' >"$app/Contents/Resources/release/lib/nif.so"
  printf '#!/bin/sh\n' >"$app/Contents/Resources/release/bin/wardmast"
  chmod +x "$app/Contents/Resources/release/bin/wardmast"
}

make_shims() {
  local dir="$1"
  mkdir -p "$dir"
  for tool in codesign security xcrun hdiutil ditto spctl; do
    cat >"$dir/$tool" <<'SHIM'
#!/usr/bin/env bash
tool="$(basename "$0")"
echo "$tool $*" >>"$SHIM_LOG"
case "$tool $1" in
  "security find-identity")
    echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Example Org (TEAM123456)"'
    echo '     1 valid identities found' ;;
  "hdiutil create") eval "last=\${$#}"; : >"$last" ;;
  "ditto -c") eval "last=\${$#}"; : >"$last" ;;
  "xcrun notarytool")
    if [ "${SHIM_NOTARY_FAIL:-}" = 1 ]; then echo "status: Invalid"; exit 0; fi
    echo "status: Accepted" ;;
esac
exit 0
SHIM
    chmod +x "$dir/$tool"
  done
}

# run <case-name> <env assignments...> -> sets $out (output dir), $log, $code
run() {
  local name="$1"
  shift
  local d="$root/$name"
  mkdir -p "$d"
  make_app "$d/Arbiter.app"
  make_shims "$d/shims"
  : >"$d/log"
  out="$d/out"
  log="$d/log"
  set +e
  env -i PATH="$d/shims:/usr/bin:/bin" HOME="$d" TMPDIR="$d" RUNNER_TEMP="$d" \
    SHIM_LOG="$d/log" "$@" \
    "$script" "$d/Arbiter.app" "$out" 1.2.3 arm64 >"$d/stdout" 2>"$d/stderr"
  code=$?
  set -e
}

line_no() { grep -n -m1 -- "$1" "$log" | cut -d: -f1; }

# --- 1. no secrets: unsigned, labelled, ad hoc only ---------------------------
run unsigned
[ "$code" = 0 ] || fail "unsigned: exit $code: $(cat "$root/unsigned/stderr")"
[ -f "$out/Arbiter-1.2.3-macos-arm64-unsigned.dmg" ] \
  && ok "unsigned dmg is labelled -unsigned" || fail "unsigned: dmg name: $(ls "$out" 2>&1)"
! grep -q "notarytool\|--timestamp\|security create-keychain" "$log" \
  && ok "unsigned: no keychain, no notarisation, no timestamp" || fail "unsigned: touched signing machinery"
grep -q "^codesign .*--sign - .*Arbiter.app\$" "$log" \
  && ok "unsigned: app is ad hoc signed" || fail "unsigned: app not ad hoc signed"
grep -q "unsigned" "$out/SIGNING_STATUS" && ok "unsigned: status file says so" || fail "unsigned: status file"

# --- 2. everything present: signed, notarised, stapled, verified --------------
run full APPLE_CERTIFICATE=Zm9v APPLE_CERTIFICATE_PASSWORD=pw APPLE_ID=a@b.c \
  APPLE_PASSWORD=app-pw APPLE_TEAM_ID=TEAM123456
[ "$code" = 0 ] || fail "full: exit $code: $(cat "$root/full/stderr")"
[ -f "$out/Arbiter-1.2.3-macos-arm64.dmg" ] \
  && ok "notarised dmg has no label suffix" || fail "full: dmg name: $(ls "$out" 2>&1)"
nested_beam="$(line_no "codesign .*release/erts/bin/beam.smp")"
nested_nif="$(line_no "codesign .*release/lib/nif.so")"
app_sign="$(line_no "codesign .*--entitlements .*Arbiter.app\$")"
if [ -n "$nested_beam" ] && [ -n "$nested_nif" ] && [ -n "$app_sign" ] \
  && [ "$nested_beam" -lt "$app_sign" ] && [ "$nested_nif" -lt "$app_sign" ]; then
  ok "nested Mach-O files are signed before the app"
else
  fail "full: signing order (beam=$nested_beam nif=$nested_nif app=$app_sign)"
fi
! grep -q "codesign .*release/bin/wardmast" "$log" \
  && ok "non-Mach-O files are not signed" || fail "full: signed a shell script"
grep -q "codesign .*--options runtime.*--timestamp.*beam.smp\|codesign .*--timestamp.*--options runtime.*beam.smp" "$log" \
  && ok "hardened runtime + timestamp on nested binaries" || fail "full: runtime/timestamp flags"
grep -q "codesign .*--entitlements .*beam.smp" "$log" \
  && ok "entitlements on nested binaries (the BEAM JIT needs them)" || fail "full: entitlements on beam.smp"
sub="$(line_no "notarytool submit")"; stap="$(line_no "stapler staple")"; mk="$(line_no "hdiutil create")"
if [ -n "$sub" ] && [ -n "$stap" ] && [ -n "$mk" ] && [ "$sub" -lt "$stap" ] && [ "$stap" -lt "$mk" ]; then
  ok "app is notarised and stapled before the dmg is built"
else
  fail "full: notarise/staple/dmg order ($sub $stap $mk)"
fi
[ "$(grep -c "notarytool submit" "$log")" = 2 ] \
  && ok "the dmg is notarised too" || fail "full: expected 2 notarytool submits"
grep -q "spctl .*--type execute" "$log" && grep -q "spctl .*--type open" "$log" \
  && ok "Gatekeeper assessment of app and dmg" || fail "full: spctl checks"
grep -q "codesign --verify --deep --strict" "$log" \
  && ok "codesign --verify --deep --strict" || fail "full: codesign verify"
grep -q "security delete-keychain" "$log" \
  && ok "temporary keychain is deleted" || fail "full: keychain not cleaned up"
! grep -q "app-pw\|Zm9v" "$root/full/stdout" "$root/full/stderr" \
  && ok "secrets are not echoed" || fail "full: a secret reached the output"

# --- 3. signed, but no notarisation credentials --------------------------------
run signed APPLE_CERTIFICATE=Zm9v APPLE_CERTIFICATE_PASSWORD=pw
[ "$code" = 0 ] || fail "signed: exit $code: $(cat "$root/signed/stderr")"
[ -f "$out/Arbiter-1.2.3-macos-arm64-unnotarised.dmg" ] \
  && ok "signed-only dmg is labelled -unnotarised" || fail "signed: dmg name: $(ls "$out" 2>&1)"
! grep -q "notarytool" "$log" && ok "signed-only: no notarisation attempted" || fail "signed: notarised"

# --- 4. half-configured secrets fail loudly ------------------------------------
run half APPLE_CERTIFICATE=Zm9v
[ "$code" != 0 ] && grep -q "APPLE_CERTIFICATE_PASSWORD" "$root/half/stderr" \
  && ok "certificate without password is an error" || fail "half: exit $code"
run half2 APPLE_ID=a@b.c APPLE_PASSWORD=x APPLE_TEAM_ID=T
[ "$code" != 0 ] && grep -q "APPLE_CERTIFICATE" "$root/half2/stderr" \
  && ok "notarisation credentials without a certificate is an error" || fail "half2: exit $code"

# --- 5. a rejected notarisation fails the build --------------------------------
run rejected APPLE_CERTIFICATE=Zm9v APPLE_CERTIFICATE_PASSWORD=pw APPLE_ID=a@b.c \
  APPLE_PASSWORD=x APPLE_TEAM_ID=T SHIM_NOTARY_FAIL=1
[ "$code" != 0 ] && ! ls "$out"/*.dmg >/dev/null 2>&1 \
  && ok "a rejected notarisation fails and publishes no dmg" || fail "rejected: exit $code"

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "ALL PASS"

#!/usr/bin/env bash
# Sign (when credentials exist), notarise, and package the desktop .app as a .dmg.
#
#   desktop/scripts/package-macos.sh <Arbiter.app> <out-dir> <version> [arch]
#
# Three outcomes, chosen from the environment (the names Tauri's own signing
# docs use, so a secret set up for either works for both):
#
#   APPLE_CERTIFICATE (base64 .p12) + APPLE_CERTIFICATE_PASSWORD
#       -> the app and every Mach-O file in it are signed with that Developer ID
#          identity, hardened runtime, secure timestamp, desktop/src-tauri/Entitlements.plist
#   ... and APPLE_ID + APPLE_PASSWORD (app-specific) + APPLE_TEAM_ID
#       -> the app and the .dmg are also notarised and stapled
#   none of them
#       -> an unsigned build: ad hoc signed so it runs on the machine that built
#          it, and the .dmg is named ...-unsigned.dmg. Gatekeeper warns on any
#          other Mac.
#
# Half a configuration (a certificate without its password, notarisation
# credentials without a certificate) is an error, not a silent downgrade: an
# operator who thinks releases are signed must not get unsigned ones.
#
# The .dmg is named Arbiter-<version>-macos-<arch>[-unsigned|-unnotarised].dmg;
# <out-dir>/SIGNING_STATUS says which of the three it is. A rejected
# notarisation fails the script and leaves no .dmg behind.
#
# Nested Mach-O files (erts, the NIFs) are signed first, the app last: a signed
# app seals its contents, so signing a file inside it afterwards breaks the seal.
# Offline-testable with fake tools: desktop/scripts/test-package-macos.sh.
set -euo pipefail

app="${1:?usage: package-macos.sh <Arbiter.app> <out-dir> <version> [arch]}"
out="${2:?usage: package-macos.sh <Arbiter.app> <out-dir> <version> [arch]}"
version="${3:?usage: package-macos.sh <Arbiter.app> <out-dir> <version> [arch]}"
arch="${4:-arm64}"
entitlements="${ENTITLEMENTS:-$(cd "$(dirname "$0")/../src-tauri" && pwd)/Entitlements.plist}"

die() { echo "package-macos: $*" >&2; exit 1; }
[ -d "$app" ] || die "$app is not a directory"
app="$(cd "$app" && pwd)"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

have_cert=0 have_notary=0
[ -n "${APPLE_CERTIFICATE:-}" ] && have_cert=1
if [ "$have_cert" = 1 ] && [ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]; then
  die "APPLE_CERTIFICATE is set but APPLE_CERTIFICATE_PASSWORD is not"
fi
if [ -n "${APPLE_ID:-}${APPLE_PASSWORD:-}${APPLE_TEAM_ID:-}" ]; then
  [ "$have_cert" = 1 ] || die "notarisation credentials are set but APPLE_CERTIFICATE is not: it cannot notarise without signing"
  { [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; } \
    || die "notarisation needs all of APPLE_ID, APPLE_PASSWORD and APPLE_TEAM_ID"
  have_notary=1
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pkgmacos.XXXXXX")"
keychain=""
cleanup() {
  if [ -n "$keychain" ]; then security delete-keychain "$keychain" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

# Every Mach-O file under the app (by magic number, not by name or mode).
macho_files() {
  local f
  while IFS= read -r -d '' f; do
    case "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" in
      cffaedfe | feedfacf | cefaedfe | feedface | cafebabe | bebafeca) printf '%s\0' "$f" ;;
    esac
  done < <(find "$app" -type f -print0)
}

# Submit <path> (a .zip or .dmg) and fail unless Apple says Accepted.
notarise() {
  local path="$1" result
  result="$(xcrun notarytool submit "$path" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait --timeout 45m 2>&1)" || {
    echo "${result//"$APPLE_PASSWORD"/***}" >&2
    die "notarytool failed for $(basename "$path")"
  }
  echo "$result" | grep -q "status: Accepted" || {
    echo "$result" >&2
    die "notarisation of $(basename "$path") was not accepted"
  }
  echo "notarised: $(basename "$path")"
}

if [ "$have_cert" = 1 ]; then
  # A throwaway keychain, so the certificate never lands in the login keychain.
  keychain="$work/signing.keychain-db"
  kc_pass="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s' "$APPLE_CERTIFICATE" | base64 --decode >"$work/cert.p12"
  security create-keychain -p "$kc_pass" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$kc_pass" "$keychain"
  security import "$work/cert.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pass" "$keychain" >/dev/null
  security list-keychains -d user -s "$keychain" login.keychain-db
  rm -f "$work/cert.p12"
  identity="${APPLE_SIGNING_IDENTITY:-}"
  if [ -z "$identity" ]; then
    identity="$(security find-identity -v -p codesigning "$keychain" \
      | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
  fi
  [ -n "$identity" ] || die "no 'Developer ID Application' identity in the imported certificate"

  sign=(codesign --force --options runtime --timestamp --entitlements "$entitlements"
    --sign "$identity" --keychain "$keychain")
  count=0
  while IFS= read -r -d '' f; do
    "${sign[@]}" "$f"
    count=$((count + 1))
  done < <(macho_files)
  echo "signed $count nested Mach-O file(s)"
  "${sign[@]}" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  status="signed"
else
  # Unsigned: still seal the bundle ad hoc so arm64 macOS will run it locally.
  codesign --force --deep --sign - "$app"
  codesign --verify --deep --strict "$app"
  status="unsigned"
fi

if [ "$have_notary" = 1 ]; then
  ditto -c -k --keepParent "$app" "$work/app.zip"
  notarise "$work/app.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
  status="notarised"
fi

case "$status" in
  unsigned) suffix="-unsigned" ;;
  signed) suffix="-unnotarised" ;;
  *) suffix="" ;;
esac
dmg="$out/Arbiter-${version}-macos-${arch}${suffix}.dmg"
rm -f "$dmg"

stage="$work/dmg"
mkdir -p "$stage"
# ditto keeps the signature, xattrs and symlinks that cp -R can mangle.
ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Arbiter" -srcfolder "$stage" -ov -format UDZO "$dmg"

if [ "$have_cert" = 1 ]; then
  codesign --force --timestamp --sign "$identity" --keychain "$keychain" "$dmg"
  codesign --verify --strict --verbose=2 "$dmg"
fi
if [ "$have_notary" = 1 ]; then
  notarise "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
fi

case "$status" in
  unsigned) note="UNSIGNED: not signed with a Developer ID and not notarised. Gatekeeper will warn; right-click > Open to run it." ;;
  signed) note="SIGNED but NOT NOTARISED: Developer ID signature only; Gatekeeper will still warn." ;;
  *) note="SIGNED and NOTARISED (Developer ID, hardened runtime, ticket stapled)." ;;
esac
{
  echo "status=$status"
  echo "dmg=$(basename "$dmg")"
  echo "$note"
} >"$out/SIGNING_STATUS"
echo "$note"
echo "wrote $dmg"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "dmg=$dmg"; echo "status=$status"; } >>"$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "### macOS .dmg: $(basename "$dmg")" >>"$GITHUB_STEP_SUMMARY"
  echo "$note" >>"$GITHUB_STEP_SUMMARY"
fi

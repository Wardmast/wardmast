#!/usr/bin/env bash
# macOS counterpart of scripts/check-release-shared-libs.sh (bd-6uq02m): refuse
# to ship a darwin release containing a Mach-O binary that links a dynamic
# library which will not exist on a user's Mac.
#
# Every Mach-O file's `otool -L` entries must be a system library (/usr/lib,
# /System/Library) or relative to the binary itself (@rpath, @loader_path,
# @executable_path). A Homebrew path (/opt/homebrew/..., /usr/local/...) is
# the typical failure: the crypto NIF linked against `brew install openssl@3`
# instead of the static OpenSSL scripts/build-release-otp.sh builds.
#
# Needs `otool` (Xcode command line tools); override with $OTOOL.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/check-release-macho-libs.sh <path>...

  <path>  An assembled release directory, an OTP install root, or a release
          tarball (.tar.gz / .tgz / .tar). May be repeated.

Exit status: 0 when every linked library is a system or relative one; 1 when
one is not (each file and library is named), nothing Mach-O was found, or the
arguments were wrong.
USAGE
}

PATHS=()
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
    *) PATHS+=("$arg") ;;
  esac
done

if [ ${#PATHS[@]} -eq 0 ]; then
  usage >&2
  exit 1
fi

OTOOL="${OTOOL:-otool}"
if ! command -v "$OTOOL" >/dev/null 2>&1; then
  echo "error: '$OTOOL' not found — install the Xcode command line tools." >&2
  exit 1
fi

TMP_ROOT=""
cleanup() {
  if [ -n "$TMP_ROOT" ]; then rm -rf "$TMP_ROOT"; fi
}
trap cleanup EXIT

# Thin (feedface/feedfacf, either endianness) and fat (cafebabe) Mach-O magic.
is_macho() {
  case "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" in
    cffaedfe | feedfacf | cefaedfe | feedface | cafebabe | bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}

allowed() {
  case "$1" in
    /usr/lib/* | /System/Library/* | @rpath/* | @loader_path/* | @executable_path/*) return 0 ;;
    *) return 1 ;;
  esac
}

scanned=0
bad=0

scan_dir() {
  local root="$1" file dep
  while IFS= read -r -d '' file; do
    [ -L "$file" ] && continue
    is_macho "$file" || continue
    scanned=$((scanned + 1))
    # `otool -L` prints "<file>:" (one "<file> (architecture X):" header per
    # slice of a fat binary) then one "\t<path> (compatibility ...)" line per
    # dependency. For a dylib/bundle (e.g. a `-dynamiclib` NIF) the first entry
    # is the file's own install name (LC_ID_DYLIB), typically the absolute build
    # path, which is not a dependency: `otool -D` lists those, so skip them.
    own_ids=$("$OTOOL" -D "$file" | sed -n '/:$/!p')
    while IFS= read -r dep; do
      if [ -n "$own_ids" ] && printf '%s\n' "$own_ids" | grep -qxF -- "$dep"; then
        continue
      fi
      if ! allowed "$dep"; then
        echo "FAIL: ${file#"$root"/} links $dep, which is not a system or relative library" >&2
        bad=$((bad + 1))
      fi
    done < <("$OTOOL" -L "$file" | sed -n 's/^[[:space:]]\{1,\}\([^[:space:]]\{1,\}\) (.*/\1/p')
  done < <(find "$root" -type f -print0)
}

for path in "${PATHS[@]}"; do
  if [ -d "$path" ]; then
    scan_dir "$path"
  elif [ -f "$path" ]; then
    if [ -z "$TMP_ROOT" ]; then TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/check-macho-libs.XXXXXX"); fi
    dest="$TMP_ROOT/$(basename "$path").d"
    mkdir -p "$dest"
    tar -xf "$path" -C "$dest"
    scan_dir "$dest"
  else
    echo "error: no such path: $path" >&2
    exit 1
  fi
done

if [ "$scanned" -eq 0 ]; then
  echo "error: no Mach-O files found under: ${PATHS[*]}" >&2
  exit 1
fi

if [ "$bad" -gt 0 ]; then
  echo "error: ${bad} disallowed dynamic library dependenc(ies) in ${scanned} Mach-O file(s)" >&2
  exit 1
fi

echo "OK: ${scanned} Mach-O file(s) link only system or relative libraries"

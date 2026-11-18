#!/bin/sh
# bd-d5mg29: prove `ward --version` runs on a release's bundled erts with no
# system Erlang. Usage: scripts/check-release-ward.sh <release-dir> <ward-escript>
# PATH is limited to the release's erts bin plus /usr/bin:/bin (no erl there on
# CI runners that matter; we assert that below).
set -eu
REL=$(cd "$1" && pwd -P)
ESCRIPT=$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")
[ -f "$REL/bin/no_dot_erlang.boot" ] || { echo "missing bin/no_dot_erlang.boot in release" >&2; exit 1; }
[ -x "$REL/bin/ward" ] || { echo "missing bin/ward in release" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$ESCRIPT" "$STAGE/ward.escript"

ERTS_BIN=$(ls -d "$REL"/erts-*/bin | head -1)
SAFE_PATH="$ERTS_BIN:/usr/bin:/bin"
if PATH="/usr/bin:/bin" command -v erl >/dev/null 2>&1; then
  echo "note: a system erl exists in /usr/bin; the check still pins erts first" >&2
fi

OUT=$(env -i HOME="$STAGE" PATH="$SAFE_PATH" WARD_ESCRIPT="$STAGE/ward.escript" "$REL/bin/ward" --version 2>&1) || {
  echo "ward --version failed: $OUT" >&2
  exit 1
}
echo "$OUT"
case "$OUT" in *ward*) ;; *) echo "unexpected output" >&2; exit 1 ;; esac

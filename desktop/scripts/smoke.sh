#!/usr/bin/env bash
# Smoke test for the built desktop app: it must start a real release, open the
# dashboard in its window, and stop the release when asked to Quit.
#
#   desktop/scripts/smoke.sh <arbiter-desktop-binary> [release-dir]
#
# With no release-dir the app falls back to its bundled `release/` resource,
# which is what an installed package does. On Linux without a $DISPLAY the app
# is wrapped in `xvfb-run`.
#
# The release needs its own config in the environment (DATABASE_PATH,
# RELEASE_DISTRIBUTION ...); the caller provides it. Its two secrets default to
# throwaway `file:` refs under the private temp dir (a CI runner has no Secret
# Service, and the shell leaves operator-set *_REF variables alone, see
# credentials::prepare_with); export both refs to use your own. Quit's drain
# check needs a token the smoke does not have, so it would open a dialog nobody
# can click: SHELL_QUIT_ANSWER defaults to `yes`. Everything the app and release
# write goes under a private temp dir.
#
# On macOS `<arbiter-desktop-binary>` is the .app's Contents/MacOS executable
# and nothing is wrapped in xvfb. Set SMOKE_EXPECT_DATA_HOME=<dir> to also
# assert where the release put its data: once it answers, <dir> must hold the
# shell's `desktop-release.json` pidfile and no stray `~/.wardmast` may exist
# (the macOS CI job points it at "$HOME/Library/Application Support/Wardmast"
# with a private HOME and no WARDMAST_DATA_HOME, so it proves the app's own default).
#
# Steps, each of which fails the script with a message:
#   1. the app starts and the release answers GET /api/version;
#   2. the webview reports it loaded the dashboard URL;
#   3. `arbiter-desktop --quit` (the same path as the tray's Quit) is accepted;
#   4. the app exits and the release's port stops answering.
set -euo pipefail

bin="${1:?usage: smoke.sh <arbiter-desktop-binary> [release-dir]}"
release="${2:-}"
bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"

# Short on purpose: unix socket paths are limited to ~100 bytes.
work="$(mktemp -d "${TMPDIR:-/tmp}/arbsmoke.XXXXXX")"
app_pid=""

cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "SMOKE FAIL: $*" >&2
  echo "--- app output ---" >&2
  tail -n 60 "$work/app.log" >&2 || true
  exit 1
}

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
url="http://127.0.0.1:${port}"

export SHELL_SOCKET="$work/shell.sock"
export SHELL_PREFERRED_PORT="$port"
export XDG_RUNTIME_DIR="$work/run"
mkdir -p "$XDG_RUNTIME_DIR"
if [ -n "$release" ]; then
  export ARBITER_RELEASE_DIR="$release"
else
  unset ARBITER_RELEASE_DIR
fi

if [ -z "${WARDMAST_CLOAK_KEY_REF:-}" ] || [ -z "${SECRET_KEY_BASE_REF:-}" ]; then
  python3 - "$work" <<'PY'
import base64, os, sys
d = sys.argv[1]
open(os.path.join(d, "cloak"), "w").write(base64.b64encode(os.urandom(32)).decode())
open(os.path.join(d, "skb"), "w").write(os.urandom(64).hex())
PY
  export WARDMAST_CLOAK_KEY_REF="file:$work/cloak"
  export SECRET_KEY_BASE_REF="file:$work/skb"
fi
export SHELL_QUIT_ANSWER="${SHELL_QUIT_ANSWER:-yes}"

runner=()
if [ "$(uname -s)" = Linux ] && [ -z "${DISPLAY:-}" ]; then
  runner=(xvfb-run -a)
fi

${runner[@]+"${runner[@]}"} "$bin" >"$work/app.log" 2>&1 &
app_pid=$!

wait_for() { # <description> <timeout-s> <command...>
  local what="$1" limit="$2"
  shift 2
  local i
  for ((i = 0; i < limit * 2; i++)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    kill -0 "$app_pid" 2>/dev/null || fail "app exited while waiting for: $what"
    sleep 0.5
  done
  fail "timed out after ${limit}s waiting for: $what"
}

wait_for "release to answer $url/api/version" 120 curl -fsS --max-time 2 "$url/api/version"
echo "ok: release is up on $url"

if [ -n "${SMOKE_EXPECT_DATA_HOME:-}" ]; then
  [ -f "$SMOKE_EXPECT_DATA_HOME/desktop-release.json" ] \
    || fail "no desktop-release.json under SMOKE_EXPECT_DATA_HOME=$SMOKE_EXPECT_DATA_HOME"
  if [ -e "${HOME}/.wardmast" ] && [ "$SMOKE_EXPECT_DATA_HOME" != "${HOME}/.wardmast" ]; then
    fail "the release also used ${HOME}/.wardmast"
  fi
  echo "ok: data home is $SMOKE_EXPECT_DATA_HOME"
fi

wait_for "webview to load the dashboard" 60 grep -q "page loaded $url/" "$work/app.log"
echo "ok: window loaded the dashboard"

"$bin" --quit || fail "--quit was not accepted by the running app"
echo "ok: quit request accepted"

for ((i = 0; i < 120; i++)); do
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$app_pid" 2>/dev/null; then fail "app still running 60s after Quit"; fi
wait "$app_pid" || true
app_pid=""
echo "ok: app exited"

if curl -fsS --max-time 2 "$url/api/version" >/dev/null 2>&1; then
  fail "release still answering on $url after Quit"
fi
echo "ok: release stopped with the app"
echo "SMOKE PASS"

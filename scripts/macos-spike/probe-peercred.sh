#!/usr/bin/env bash
# LOCAL_PEERCRED / LOCAL_PEERPID through :inet.getopts raw on an Erlang
# unix-socket listener. Needs `escript` on PATH (setup-beam or brew).
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init peercred

command -v escript >/dev/null 2>&1 || inconclusive "no escript on PATH"
erl -noshell -eval 'io:format("OTP ~s~n",[erlang:system_info(otp_release)]), halt().'
dir=$(mktemp -d)
out=$(escript "$(dirname "$0")/peercred.escript" "$dir" 2>&1)
echo "$out"
case "$out" in
  *"RESULT ok"*) pass "LOCAL_PEERCRED uid and LOCAL_PEERPID read via inet:getopts raw match the peer" ;;
  *"RESULT pid-mismatch"*) fail "LOCAL_PEERCRED worked but LOCAL_PEERPID differed from the peer pid" ;;
  *"RESULT uid-mismatch"*) fail "LOCAL_PEERCRED uid did not match the peer uid" ;;
  *"badmatch"*|*"einval"*|*"enoprotoopt"*) fail "inet:getopts raw failed (see log)" ;;
  *) inconclusive "escript did not complete (see log)" ;;
esac

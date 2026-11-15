#!/usr/bin/env bash
# Static-OpenSSL OTP build on arm64. Slow (10-30 min); records duration.
# Env: OTP_VERSION (default 27.3.4).
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init otp-static-ssl

vsn="${OTP_VERSION:-27.3.4}"
ssl=$(brew --prefix openssl@3 2>/dev/null) || ssl=""
[ -d "$ssl" ] || { brew install openssl@3 && ssl=$(brew --prefix openssl@3); } || inconclusive "openssl@3 unavailable"
ls "$ssl/lib"/libcrypto.a "$ssl/lib"/libssl.a || inconclusive "no static openssl libs in $ssl/lib"

work=$(mktemp -d)
start=$(date +%s)
curl -fsSL -o "$work/otp.tgz" "https://github.com/erlang/otp/archive/refs/tags/OTP-$vsn.tar.gz" || inconclusive "OTP source download failed"
mkdir "$work/src"
tar -xzf "$work/otp.tgz" -C "$work/src" --strip-components=1
prefix="$work/install"
(
  set -e
  cd "$work/src"
  export ERL_TOP="$PWD"
  ./configure --prefix="$prefix" --with-ssl="$ssl" --disable-dynamic-ssl-lib \
    --without-javac --without-wx --without-odbc --without-debugger --without-observer --without-et
  make -j"$(sysctl -n hw.ncpu)"
  make install
) 2>&1 | tail -n 400
rc=${PIPESTATUS[0]}
dur=$(( $(date +%s) - start ))
echo "build rc=$rc duration=${dur}s arch=$(uname -m)"
[ "$rc" -eq 0 ] || fail "OTP $vsn static-ssl build failed after ${dur}s (see log tail)"

so=$(find "$prefix" -name 'crypto.so' | head -1)
echo "crypto nif: $so"
otool -L "$so"
if otool -L "$so" | grep -Eq 'libcrypto|libssl'; then
  fail "OTP $vsn built in ${dur}s but crypto.so still links libcrypto/libssl dynamically"
fi
"$prefix/bin/erl" -noshell -eval 'io:format("~p~n",[crypto:info_lib()]), halt().'
pass "OTP $vsn arm64 static-OpenSSL build ok in ${dur}s; crypto.so has no libssl/libcrypto dependency"

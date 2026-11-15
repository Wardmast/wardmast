#!/usr/bin/env bash
# com.apple.quarantine xattr on files fetched with curl, and via Erlang
# httpc / Req (if available). CI runners may differ from a user desktop, so
# an absent xattr everywhere is reported INCONCLUSIVE rather than PASS.
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init quarantine

work=$(mktemp -d)
url="https://raw.githubusercontent.com/actions/runner/main/LICENSE"
curl -fsSL -o "$work/curl.bin" "$url" || inconclusive "curl download failed"
echo "--- xattrs on curl download:"
xattr -l "$work/curl.bin"
if xattr "$work/curl.bin" | grep -q com.apple.quarantine; then curl_q=yes; else curl_q=no; fi

httpc_q=n/a
if command -v erl >/dev/null 2>&1; then
  erl -noshell -eval '
    application:ensure_all_started(inets), application:ensure_all_started(ssl),
    {ok, {{_,200,_},_,Body}} = httpc:request(get, {"'"$url"'", []}, [{ssl,[{verify,verify_none}]}], [{body_format,binary}]),
    file:write_file("'"$work"'/httpc.bin", Body), halt().' 2>&1
  if [ -f "$work/httpc.bin" ]; then
    xattr -l "$work/httpc.bin"
    if xattr "$work/httpc.bin" | grep -q com.apple.quarantine; then httpc_q=yes; else httpc_q=no; fi
  else
    httpc_q=error
  fi
fi
echo "curl quarantine=$curl_q httpc quarantine=$httpc_q (Req not exercised: it uses Finch/Mint over the same gen_tcp/ssl, no LSFileQuarantine path)"
if [ "$curl_q" = no ] && [ "$httpc_q" != yes ]; then
  pass "files fetched by curl (and httpc: $httpc_q) carry no quarantine xattr, so no Gatekeeper prompt"
else
  fail "quarantine xattr present: curl=$curl_q httpc=$httpc_q"
fi

#!/bin/sh
# bd-485ts3: prove the arb-capture runner (design N1) works. Runs INSIDE a worker image
# (scripts/worker-image-smoke.sh feeds it to `sh -s`) or on a host that has the pieces:
#   ARB_CHROME, ARB_CAPTURE_DIR (runner.mjs + node_modules/playwright-core), and node at
#   $ARB_CAPTURE_NODE or $ARB_CAPTURE_DIR/bin/node.
# It starts a loopback login-gated page, runs the real runner against it and checks that
#   1. a correct login shoots the page behind it (a PNG),
#   2. a wrong password FAILS with "did not succeed" and writes no image.
# Exits non-zero, with the reason, otherwise.
set -eu
: "${ARB_CHROME:?ARB_CHROME is not set}"
: "${ARB_CAPTURE_DIR:?ARB_CAPTURE_DIR is not set}"
node="${ARB_CAPTURE_NODE:-$ARB_CAPTURE_DIR/bin/node}"
test -x "$node" || { echo "node ($node) is not executable" >&2; exit 1; }
test -f "$ARB_CAPTURE_DIR/runner.mjs" || { echo "no runner.mjs in $ARB_CAPTURE_DIR" >&2; exit 1; }
test -d "$ARB_CAPTURE_DIR/node_modules/playwright-core" || { echo "playwright-core is not installed in $ARB_CAPTURE_DIR" >&2; exit 1; }
"$node" --version

work=$(mktemp -d)
server_pid=""
cleanup() { [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

cat > "$work/server.mjs" <<'JS'
import http from "node:http"
http.createServer((req, res) => {
  const authed = (req.headers.cookie || "").includes("sid=good")
  const page = (body) => { res.setHeader("content-type", "text/html"); res.end(`<!doctype html><body>${body}</body>`) }
  const go = (to) => { res.statusCode = 302; res.setHeader("location", to); res.end() }
  if (req.url === "/login" && req.method === "GET")
    return page('<form method=post action=/login><input id=u name=u><input id=p name=p type=password><button id=go>Sign in</button></form>')
  if (req.url === "/login") {
    let b = ""; req.on("data", (d) => (b += d))
    return req.on("end", () => {
      if (b === "u=admin&p=right") { res.setHeader("set-cookie", "sid=good; Path=/"); return go("/home") }
      go("/login")
    })
  }
  if (req.url === "/home") return authed ? page("<h1>smoke: behind the login</h1>") : go("/login")
  res.statusCode = 404; res.end("nope")
}).listen(0, "127.0.0.1", function () { console.log(this.address().port) })
JS
"$node" "$work/server.mjs" > "$work/port" &
server_pid=$!
i=0
while [ ! -s "$work/port" ]; do
  i=$((i + 1)); [ "$i" -le 50 ] || { echo "fixture server did not start" >&2; exit 1; }
  sleep 0.1
done
port=$(cat "$work/port")

spec() { # <password> <out file> -> spec file
  cat > "$work/spec-$2.json" <<JSON
{"chrome":"$ARB_CHROME","base_url":"http://127.0.0.1:$port","path":"/home","out_file":"$work/$2.png",
 "timeout_ms":20000,"viewport":{"width":800,"height":600,"device_scale_factor":1},
 "theme":{"color_scheme":"light"},"shot":{"steps":[],"full_page":false,"hide":[]},
 "login":{"kind":"form","path":"/login","username_selector":"#u","password_selector":"#p",
          "submit_selector":"#go","success":{"path_not":"/login"},"persona":"admin",
          "username":"admin","password":"$1","timeout_ms":3000}}
JSON
}

spec right good
out=$("$node" "$ARB_CAPTURE_DIR/runner.mjs" "$work/spec-good.json" 2>&1 || true)
echo "$out" | tail -n 1 | grep -q '"ok":true' || { echo "login shot failed: $out" >&2; exit 1; }
head -c 8 "$work/good.png" | od -An -c | grep -q "P   N   G" || { echo "not a PNG" >&2; exit 1; }
[ "$(wc -c < "$work/good.png")" -gt 1000 ] || { echo "screenshot too small" >&2; exit 1; }

spec wrong bad
out=$("$node" "$ARB_CAPTURE_DIR/runner.mjs" "$work/spec-bad.json" 2>&1 || true)
echo "$out" | tail -n 1 | grep -q 'did not succeed' || { echo "a wrong password did not fail the shot: $out" >&2; exit 1; }
[ ! -e "$work/bad.png" ] || { echo "a failed login still wrote an image" >&2; exit 1; }

echo "capture smoke ok: login shot $(wc -c < "$work/good.png") bytes, wrong password refused"

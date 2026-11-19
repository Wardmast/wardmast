#!/bin/sh
# bd-6301r0: prove a page can be screenshotted inside a worker image.
# Usage: scripts/worker-image-smoke.sh <image> [podman|docker]
# Runs headless Chromium in the image against a data: page and checks that a
# non-empty PNG comes out. Exits non-zero (with the reason) otherwise.
set -eu
image="${1:?usage: worker-image-smoke.sh <image> [podman|docker]}"
engine="${2:-docker}"
"$engine" run --rm --entrypoint /bin/sh "$image" -ec '
  test -x "$ARB_CHROME" || { echo "ARB_CHROME=$ARB_CHROME is not executable" >&2; exit 1; }
  "$ARB_CHROME" --version
  out=$(mktemp -d)
  "$ARB_CHROME" --headless --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --window-size=800,600 --screenshot="$out/shot.png" \
    "data:text/html,<h1 style=%22font-family:sans-serif%22>arbiter smoke</h1>"
  size=$(wc -c < "$out/shot.png")
  head -c 8 "$out/shot.png" | od -An -c | grep -q "P   N   G" || { echo "not a PNG" >&2; exit 1; }
  [ "$size" -gt 1000 ] || { echo "screenshot too small: $size bytes" >&2; exit 1; }
  echo "smoke ok: screenshot $size bytes"
'

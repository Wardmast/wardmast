#!/usr/bin/env bash
# bd-71t1wd: fail when a built release lacks the vendored host capture runner dependency,
# or when it does not match the version pinned by priv/capture/package-lock.json.
# Usage: scripts/check-release-capture.sh <release-dir> <version>
set -euo pipefail
rel="${1:?release dir}"
ver="${2:?release version}"
dir="${rel}/lib/wardmast-${ver}/priv/capture"
pkg="${dir}/node_modules/playwright-core/package.json"
[ -f "$pkg" ] || { echo "missing ${pkg}: playwright-core was not vendored" >&2; exit 1; }
node -e '
const fs = require("fs");
const [dir, pkg] = process.argv.slice(1);
const pinned = JSON.parse(fs.readFileSync(dir + "/package-lock.json", "utf8")).packages["node_modules/playwright-core"].version;
const got = JSON.parse(fs.readFileSync(pkg, "utf8")).version;
if (pinned !== got) { console.error(`playwright-core ${got} != pinned ${pinned}`); process.exit(1); }
console.log(`playwright-core ${got} vendored and matches the lockfile`);
' "$dir" "$pkg"
(cd "$dir" && node -e "import('playwright-core').then(() => console.log('playwright-core resolves'))")

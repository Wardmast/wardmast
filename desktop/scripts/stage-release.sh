#!/usr/bin/env bash
# Stage a Wardmast release for bundling into the desktop app.
#
#   desktop/scripts/stage-release.sh <release-dir-or-tarball>
#
# The bundle config (src-tauri/tauri.release.conf.json) ships
# `src-tauri/release-bundle/` as the app's `release/` resource, which is where
# the shell looks for `bin/wardmast` (unless ARBITER_RELEASE_DIR overrides it).
# Accepts either an unpacked release (e.g. _build/prod/rel/wardmast) or the
# release tarball CI publishes (its root is the release directory itself).
set -euo pipefail

src="${1:?usage: stage-release.sh <release-dir-or-tarball>}"
dest="$(cd "$(dirname "$0")/.." && pwd)/src-tauri/release-bundle"

rm -rf "$dest"
mkdir -p "$dest"
if [ -d "$src" ]; then
  # -a keeps the exec bits and, deliberately, any symlink: the bundler copies
  # what it finds. (The published tarball has none.)
  cp -a "$src"/. "$dest"/
else
  tar -xzf "$src" -C "$dest"
fi

if [ ! -x "$dest/bin/wardmast" ]; then
  echo "stage-release: $dest/bin/wardmast is missing or not executable" >&2
  exit 1
fi
echo "staged release at $dest"

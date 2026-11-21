#!/usr/bin/env bash
# bd-7w4e4s: fail when a release tarball contains ANY symlink. `ward server deploy`'s safe
# unpacker rejects every symlink entry (unsafe_symlink), so one in the tarball makes the
# release undeployable. Usage: scripts/check-release-no-symlinks.sh <tarball.tar.gz>
set -euo pipefail
tb="${1:?tarball}"
bad="$(tar -tvzf "$tb" | grep -E '^[lh]' || true)"
if [ -n "$bad" ]; then
  echo "release tarball contains symlinks/hardlinks (ward server deploy would reject it):" >&2
  echo "$bad" >&2
  exit 1
fi
echo "no symlinks in ${tb}"

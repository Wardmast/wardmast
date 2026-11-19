#!/bin/sh
# Stands in for headless Chromium in tests: writes the --screenshot target.
for a in "$@"; do
  case "$a" in
    --screenshot=*) out="${a#--screenshot=}" ;;
  esac
  last="$a"
done
printf 'IMG %s' "$last" > "$out"

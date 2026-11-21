#!/bin/sh
# Stands in for headless Chromium in tests: writes the --screenshot target, or (--dump-dom) prints
# the page's DOM, which the shooter reads its text from for the data-safety scan.
for a in "$@"; do
  case "$a" in
    --screenshot=*) out="${a#--screenshot=}" ;;
    --dump-dom) dump=1 ;;
  esac
  last="$a"
done
if [ -n "$dump" ]; then
  printf '<html><body><p>fake page %s</p></body></html>' "$last"
  exit 0
fi
printf 'IMG %s' "$last" > "$out"

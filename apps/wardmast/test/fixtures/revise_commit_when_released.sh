#!/bin/sh
# Fixture: an IMPLEMENTER worker that commits like `revise_commit.sh`, but only
# once a test releases it. $1 is a path; the script blocks until that file
# exists, then runs `revise_commit.sh` unchanged.
#
# Why: a test that wants to inspect the gate *while a fix round is in flight*
# cannot use `revise_commit.sh` (it finishes within milliseconds, so the gate
# advances to the next review round on its own clock and a state sample races
# it) nor `revise_hang.sh` (it never finishes). Blocking on a file the test
# controls pins the gate in the round under inspection for exactly as long as
# the test needs. Never invokes the paid CLI.
release="$1"
until [ -e "$release" ]; do
  sleep 0.05
done
exec "$(dirname "$0")/revise_commit.sh"

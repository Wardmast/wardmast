#!/bin/sh
# Fixture (bd-3na3d7): a reviewer session that ends cleanly (exit 0) while its
# last tool call -- a long `mix test` -- never got a result line, exactly the
# shape of the cluster-pod reviewer transcripts that stopped mid-call. No VERDICT.
echo "reading the diff"
echo "⏵ Bash(timeout 300 mix test test/wardmast/foo_test.exs)"
exit 0

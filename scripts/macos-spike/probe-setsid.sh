#!/usr/bin/env bash
# `perl -MPOSIX` setsid wrapper (macOS has no setsid(1)): the child must get a
# new session and process group, distinct from the caller's.
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
probe_init setsid

command -v perl >/dev/null 2>&1 || inconclusive "no perl"
parent=$(ps -o sess=,pgid= -p $$ | tr -s ' ')
child=$(perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec @ARGV' ps -o pid=,sess=,pgid= -p '$$' 2>&1)
# `ps` above got a literal; use a shell child to report its own ids instead.
child=$(perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec @ARGV' sh -c 'ps -o pid=,pgid=,sess= -p $$')
echo "parent (sess pgid): $parent"
echo "child  (pid pgid sess): $child"
cpid=$(echo "$child" | awk '{print $1}')
cpgid=$(echo "$child" | awk '{print $2}')
ppgid=$(ps -o pgid= -p $$ | tr -d ' ')
[ -n "$cpid" ] || inconclusive "could not read child ids"
if [ "$cpgid" = "$cpid" ] && [ "$cpgid" != "$ppgid" ]; then
  pass "child is its own session/pgid leader (pgid=$cpgid), parent pgid=$ppgid"
else
  fail "child pgid=$cpgid pid=$cpid parent pgid=$ppgid: no new session"
fi

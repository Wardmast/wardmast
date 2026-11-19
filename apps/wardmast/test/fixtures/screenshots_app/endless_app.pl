#!/usr/bin/perl
# A fixture "app" whose every response is 200 with a body that does not end (bd-bhrsdv): the
# capture's own probes must read the status and stop, never the body.
#
# It trickles rather than floods, so a probe that wrongly reads the body only waits (and fails
# on its timeout) instead of filling the test VM's memory: 1 KiB every 20 ms, written unbuffered,
# at most 2 MiB per connection, and a connection's child exits as soon as the reader hangs up.
# The whole app ends itself after 5 minutes, so even a missed cleanup cannot leave it running.
use strict;
use warnings;
use IO::Socket::INET;

$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';
alarm 300;

my $srv = IO::Socket::INET->new(
  LocalAddr => '127.0.0.1', LocalPort => $ENV{PORT}, Listen => 10, ReuseAddr => 1
) or die "listen: $!";

while (my $c = $srv->accept) {
  my $pid = fork;
  if (defined $pid && $pid == 0) {
    alarm 120;
    close $srv;
    while (my $h = <$c>) { last if $h =~ /^\r?\n$/ }
    syswrite($c, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n") or exit 0;
    my $chunk = 'x' x 1024;
    for (1 .. 2048) {
      defined(syswrite($c, $chunk)) or exit 0;
      select(undef, undef, undef, 0.02);
    }
    exit 0;
  }
  close $c;
}

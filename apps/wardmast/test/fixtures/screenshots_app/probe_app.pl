#!/usr/bin/perl
# The capture-sandbox probe app (bd-bhrsdv). `perl probe_app.pl` tries every way out the sandbox
# must close (the coordinator's loopback port, an external address and name, a host file, a
# write outside its tree), then serves that report for every path on $PORT.
# `perl probe_app.pl --probe <host> <port>` makes one TCP connect and prints the result: the
# setup command's probe, and the test's unsandboxed control.
use strict;
use warnings;
use Socket;
use IO::Socket::INET;

sub tcp {
  my ($host, $port) = @_;
  my $addr = inet_aton($host);
  return "failed: no address for $host" unless defined $addr;
  socket(my $s, PF_INET, SOCK_STREAM, 0) or return "failed: socket: $!";
  if (connect($s, sockaddr_in($port, $addr))) { close $s; return 'connected' }
  return "failed: $!";
}

if (@ARGV && $ARGV[0] eq '--probe') { print tcp($ARGV[1], $ARGV[2]), "\n"; exit 0 }

sub readable {
  my ($path) = @_;
  if (open(my $f, '<', $path)) { close $f; return 'readable' }
  return "failed: $!";
}

sub writable {
  my ($path) = @_;
  if (open(my $f, '>', $path)) { print $f 'x'; close $f; unlink $path; return 'ok' }
  return "failed: $!";
}

my @lines = (
  'coordinator=' . tcp('127.0.0.1', $ENV{PROBE_COORDINATOR_PORT}),
  'external_ip=' . tcp('1.1.1.1', 80),
  'external_name=' . tcp('example.com', 80),
  'canary=' . readable($ENV{PROBE_CANARY}),
  'write_system=' . writable('/usr/arbiter-capture-probe'),
  'write_checkout=' . writable('probe-write'),
  'write_scratch=' . writable("$ENV{TMPDIR}/probe-write"),
  'host_pid=' . (-e "/proc/$ENV{PROBE_HOST_PID}" ? 'visible' : 'hidden'),
  'env=' . join(',', sort keys %ENV),
);

if (open(my $f, '<', 'setup-probe.txt')) {
  local $/;
  my $seen = <$f>;
  chomp $seen;
  push @lines, "setup_coordinator=$seen";
}

my $report = join("\n", @lines) . "\n";

my $srv = IO::Socket::INET->new(
  LocalAddr => '127.0.0.1', LocalPort => $ENV{PORT}, Listen => 10, ReuseAddr => 1
) or die "listen: $!";
$| = 1;
while (my $c = $srv->accept) {
  my $line = <$c> // '';
  while (my $h = <$c>) { last if $h =~ /^\r?\n$/ }
  print $c "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " . length($report) .
    "\r\nConnection: close\r\n\r\n$report";
  close $c;
}

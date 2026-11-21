#!/usr/bin/perl
# Stands in for headless Chromium inside the capture sandbox (bd-bhrsdv): loads the page through
# the sandbox's bridge the way a browser would, then tries the same ways out as the probe app,
# and writes all of it as the "screenshot". The coordinator port and the canary path come from
# files beside this script, because the browser's environment is built from nothing.
use strict;
use warnings;
use Socket;
use IO::Handle;
use File::Basename qw(dirname);

my ($out, $url, $dump);
for my $arg (@ARGV) {
  $out = $1 if $arg =~ /^--screenshot=(.+)$/;
  $dump = 1 if $arg eq '--dump-dom';
  $url = $arg;
}

# bd-995svb: the shooter's second run (--dump-dom) reads the page's text for the data-safety scan.
if ($dump) {
  print "<html><body><p>probe page $url</p></body></html>";
  exit 0;
}

sub slurp {
  my ($path) = @_;
  open(my $f, '<', $path) or die "$path: $!";
  local $/;
  my $v = <$f>;
  chomp $v;
  return $v;
}

my $dir = dirname($0);
my $coordinator = slurp("$dir/coordinator_port");
my $canary = slurp("$dir/canary_path");

sub tcp {
  my ($host, $port) = @_;
  my $addr = inet_aton($host);
  return "failed: no address for $host" unless defined $addr;
  socket(my $s, PF_INET, SOCK_STREAM, 0) or return "failed: socket: $!";
  if (connect($s, sockaddr_in($port, $addr))) { close $s; return 'connected' }
  return "failed: $!";
}

sub fetch {
  my ($target) = @_;
  my ($host, $port, $path) = $target =~ m{^http://([^/:]+):(\d+)(/[^#]*)?}
    or return "failed: not a url: $target";
  my $addr = inet_aton($host) or return "failed: no address for $host";
  socket(my $s, PF_INET, SOCK_STREAM, 0) or return "failed: socket: $!";
  connect($s, sockaddr_in($port, $addr)) or return "failed: $!";
  $s->autoflush(1);
  print $s 'GET ' . ($path // '/') . " HTTP/1.1\r\nHost: $host:$port\r\nConnection: close\r\n\r\n";
  local $/;
  my $response = <$s>;
  close $s;
  return $response // '';
}

my $page = fetch($url);
open(my $o, '>', $out) or die "write $out: $!";
print $o "PAGE:\n$page\n";
print $o 'BROWSER coordinator=' . tcp('127.0.0.1', $coordinator) . "\n";
print $o 'BROWSER external_ip=' . tcp('1.1.1.1', 80) . "\n";
print $o 'BROWSER external_name=' . tcp('example.com', 80) . "\n";
print $o 'BROWSER canary=' . (open(my $c, '<', $canary) ? 'readable' : "failed: $!") . "\n";
print $o 'BROWSER env=' . join(',', sort keys %ENV) . "\n";
# bd-3glf2a: a capture service is the app's, never the browser's.
print $o 'BROWSER service=' . tcp('127.0.0.1', slurp("$dir/service_port")) . "\n"
  if -e "$dir/service_port";
close $o;

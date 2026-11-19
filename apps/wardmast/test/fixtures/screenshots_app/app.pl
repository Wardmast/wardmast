#!/usr/bin/perl
# A tiny fixture "app" for the capture-step tests: serves 200 for every path listed in
# routes.txt (one per line), 500 for /boom and 404 for the rest, on $PORT.
use strict;
use warnings;
use IO::Socket::INET;

my %routes;
if (open(my $fh, '<', 'routes.txt')) {
  while (my $l = <$fh>) { chomp $l; $routes{$l} = 1 if length $l; }
  close $fh;
}
my $srv = IO::Socket::INET->new(
  LocalAddr => '127.0.0.1', LocalPort => $ENV{PORT}, Listen => 10, ReuseAddr => 1
) or die "listen: $!";
$| = 1;
while (my $c = $srv->accept) {
  my $line = <$c> // '';
  my (undef, $path) = split ' ', $line;
  $path //= '/';
  $path =~ s/\?.*//;
  while (my $h = <$c>) { last if $h =~ /^\r?\n$/ }
  my ($status, $body) =
    $path eq '/boom' ? ('500 Internal Server Error', 'boom')
    : $routes{$path} ? ('200 OK', "page $path")
    : ('404 Not Found', 'nope');
  print $c "HTTP/1.1 $status\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
  close $c;
}

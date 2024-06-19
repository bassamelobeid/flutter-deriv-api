#!/usr/bin/env perl

use strict;
use warnings;

=head1 NAME

DD.pl - capture messages that would be sent to datadog

=head1 SYNOPSIS

    DATADOG_AGENT_HOST=... \
    DATADOG_AGENT_PORT=... \
    DD.pl

=head1 DESCRIPTION

This is a replacement for the datadog agent meant to be used for development
and testing. It does not send anything to the datadog server. Instead it
simply prints the received UDP packets to stdout.

=head2 Usage

To watch what is going on on the default DD-agent port 8125, you have to
first shut down your local DD-agent:

  sudo systemctl stop datadog-agent

Next you simply start this script:

  DD.pl

It will print messages like these:

  2021-12-16 20:21:52 (127.0.0.1:40603): feed.ohlc.compare.diff:0|c
  2021-12-16 20:21:52 (127.0.0.1:40603): feed.ohlc.compare.similar:0|c

The timestamp is added by the script right when the message is received.
The C<IP:PORT> pair identifies the sender of the message. You can convert
that into a process ID by means of the C<ss> command:

  ss -nup 'sport == :40603' | cat

which will print something like:

  Recv-Q Send-Q Local Address:Port  Peer Address:Port
  0      0         127.0.0.1:40603  127.0.0.1:8125     users:(("perl",pid=12163,fd=5))

=head1 DataDog message format

See L<https://docs.datadoghq.com/developers/dogstatsd/datagram_shell/>.

=cut

use Socket qw/sockaddr_in inet_ntoa/;
use IO::Socket::INET;

my $s = IO::Socket::INET->new(
    LocalAddr => $ENV{DATADOG_AGENT_HOST} // '127.0.0.1',
    LocalPort => $ENV{DATADOG_AGENT_PORT} // 8125,
    Proto     => 'udp',
) or die "Cannot create socket: $!\n";

while ($s->recv(my $buf, 40960)) {
    my @tm = localtime;
    my ($port, $ip) = sockaddr_in $s->peername;
    $ip = inet_ntoa $ip;
    printf "%04d-%02d-%02d %02d:%02d:%02d (%s:%s): %s\n", $tm[5] + 1900, $tm[4] + 1, @tm[3, 2, 1, 0], $ip, $port, $buf;
}

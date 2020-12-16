#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Syntax::Keyword::Try;
use IO::Async::Loop;
use Ryu::Async;
use Log::Any qw($log);
use DateTime;

GetOptions(
    'help|?'      => sub { pod2usage() },
    'l|listen=s'  => \(my $udp_listen),
    's|sendto=s@' => \(my $udp_sendto),
    'g|log=s'     => \(my $log_level = "info"),
);

# validate required args are given
die "Missing --listen parameter, try --help\n" unless $udp_listen;
die "Missing --sendto parameter, try --help\n" unless $udp_sendto;

=head1 NAME

 udp_proxy - a UDP proxy to broadcast all packets received on the listening port to multiple target ports.

=head1 SYNOPSIS

  udp_proxy.pl [options]

  Options:
    --listen,   -l   host:port to listen as a udp server e.g. -l 127.0.0.1:8125
    --sendto,   -s   list of target host:ports to broadcast to, e.g. -s 127.0.0.1:8126,127.0.0.1:8127
    --log       -g   set the Log::Any logging level (default: info)

=cut

require Log::Any::Adapter;
Log::Any::Adapter->import(qw(Stderr), log_level => $log_level);

my $loop = IO::Async::Loop->new;
$loop->add(my $ryu = Ryu::Async->new);
my $srv;
my %active_clients = ();

try {
    my ($listen_host, $listen_port) = split /:/, $udp_listen;
    $srv = $ryu->udp_server(
        host => $listen_host,
        port => $listen_port,
    );
    $srv->port->get;
    $srv->incoming->completed->on_fail(
        sub {
            my $err = shift;
            my $dt  = DateTime->now;
            die "[$dt] UDP server failed - " . $err;
        });

    # Forward to these ports
    $udp_sendto = [split /,/ => join ',' => @$udp_sendto];
    setup_udp_client($ryu, $srv, $_) for $udp_sendto->@*;

    $SIG{INT} = $SIG{TERM} = sub {
        $SIG{INT} = $SIG{TERM} = sub {
            $log->errorf('Second INT/TERM received after first, hard exit');
            exit 1;
        };
        try {
            $srv->incoming->finish;
            $loop->delay_future(after => 2)->on_ready(
                sub {
                    foreach my $key (keys %active_clients) {
                        $active_clients{$key}->incoming->finish;
                        $active_clients{$key}->outgoing->source->finish;
                    }
                    $loop->stop;
                })->retain;
        } catch {
            $log->errorf('Exception while trying to handle shutdown signal: %s', $@);
        }
    };

    $loop->run;
} catch ($e) {
    my $dt = DateTime->now;
    $log->errorf("[$dt] UDP proxy failed - $e");
}

sub setup_udp_client {
    my ($ryu, $srv, $host_port) = @_;
    my @uri = split /:/, $host_port;
    my $client = $ryu->udp_client(
        host => $uri[0],
        port => $uri[1],
    );
    # We only want to send the message itself, so we can ignore the sender
    $client->outgoing->from($srv->incoming->map('payload'));
    $client->incoming->completed->on_fail(
        sub {
            my $err = shift;
            my $dt  = DateTime->now;
            $log->errorf("[$dt] UDP client failed - " . $err);
            $client->incoming->finish;
            $client->outgoing->source->finish;
            $client = undef;
            # preventing error log flooding
            $loop->delay_future(after => 10)->on_ready(
                sub {
                    setup_udp_client($ryu, $srv, $host_port);
                })->retain;
        });
    $active_clients{$host_port} = $client;
}

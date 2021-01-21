#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Syntax::Keyword::Try;
use IO::Async::Loop;
use Future::AsyncAwait;
use Ryu::Async;
use Log::Any qw($log);
use DateTime;
use IO::Socket;

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

$0 = "udp_proxy";

my $loop = IO::Async::Loop->new;
my ($srv, $ryu);
my %active_clients = ();

try {
    my ($listen_host, $listen_port) = split /:/, $udp_listen;
    $loop->add($ryu = Ryu::Async->new);
    $srv = $ryu->udp_server(
        host => $listen_host,
        port => $listen_port,
    );
    $srv->port->get;

    # Forward to these ports
    $udp_sendto = [split /,/ => join ',' => @$udp_sendto];
    setup_udp_client($_) for $udp_sendto->@*;

    check_ports($listen_host, $listen_port);

    $SIG{INT} = $SIG{TERM} = sub {
        $SIG{INT} = $SIG{TERM} = sub {
            $log->errorf('Second INT/TERM received after first, hard exit');
            exit 1;
        };
        destructor();
    };

    (
        async sub {
            await $srv->incoming->completed;
        })->()->get;

} catch ($e) {
    destructor();
    my $dt = DateTime->now;
    $log->errorf("[$dt] UDP proxy failed - $e");
};

sub setup_udp_client {
    my ($host_port, $is_reconnect) = @_;
    my @uri = split /:/, $host_port;
    my $dt  = DateTime->now;
    if (!is_alive($uri[0], $uri[1])) {
        $log->errorf("[$dt] UDP client [$host_port] failed to connect.") unless $is_reconnect;
        return;
    }
    my $client = $ryu->udp_client(
        host => $uri[0],
        port => $uri[1],
    );
    # We only want to send the message itself, so we can ignore the sender
    $client->outgoing->from($srv->incoming->map('payload'));
    $client->incoming->completed->on_fail(
        sub {
            my $err = shift;
            $dt = DateTime->now;
            $log->errorf("[$dt] UDP client [$host_port] failed - " . $err);
            $client->incoming->finish;
            $client->outgoing->source->finish;
            $client = undef;
            delete $active_clients{$host_port};
        });
    $active_clients{$host_port} = $client;
    $log->infof("[$dt] UDP client [$host_port] connected.");
}

sub check_ports {
    my ($listen_host, $listen_port) = @_;
    $loop->delay_future(after => 10)->on_ready(
        sub {
            if (!is_alive($listen_host, $listen_port)) {
                die $log->errorf("Server listening port $listen_port is closed.");
            }
            foreach my $host_port ($udp_sendto->@*) {
                setup_udp_client($host_port, 1) if (not exists($active_clients{$host_port}));
            }
            check_ports($listen_host, $listen_port);
        })->retain;
}

sub is_alive {
    my ($host, $port) = @_;
    my $sock = new IO::Socket::INET(
        LocalHost => $host,
        LocalPort => $port,
        Proto     => 'udp'
    );
    if ($sock) {
        $sock->close();
        return 0;
    }
    return 1;
}

sub destructor {
    $srv->incoming->finish;
    $loop->delay_future(after => 2)->on_ready(
        sub {
            foreach my $key (keys %active_clients) {
                $active_clients{$key}->incoming->finish;
                $active_clients{$key}->outgoing->source->finish;
            }
            $loop->stop;
        })->get;
}


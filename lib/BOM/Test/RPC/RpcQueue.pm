package BOM::Test::RPC::RpcQueue;
use strict;
use warnings;

use IO::Async::Stream;
use IO::Async::Loop;
use IO::Socket::UNIX;
use Path::Tiny;
use Log::Any qw($log);

use BOM::Test;
use BOM::Test::Script;

my $socket_path = '/tmp/binary_jobqueue_worker.sock';
my $script_path = '/home/git/regentmarkets/bom-rpc/bin/binary_jobqueue_worker.pl';

sub start_rpc_queue_if_not_running {
    if (path($socket_path)->exists) {
        my $sock = IO::Socket::UNIX->new(
            Type => SOCK_STREAM,
            Peer => $socket_path,
        );
        return if $sock;
    }

    start_rpc_queue();
    return;
}

sub start_rpc_queue {
    my $args = "--testing --workers 0 --socket $socket_path";
    system("$script_path $args &");
    my $attempts = 0;
    while (1) {

        last if ping();
        $attempts += 1;
        last if ($attempts > 5);
        sleep 1;

    }

    if ($attempts > 5) {
        #TODO: it happens in one occasion during `make security`. Should be fixed.
        $log->debug('RPC queue is not responding.\n');
    } else {
        $log->debug("RPC queue is launched with args: $args");
    }

    return;
}

sub add_worker {
    my ($redis_server) = @_;
    my $redis_url = $redis_server->url;

    start_rpc_queue_if_not_running();
    my $conn = create_socket_connection();

    $redis_url =~ /.*:(\d+)\D?$/;
    $redis_url = 'redis://127.0.0.1:' . $1;

    $log->debug('Starting an rpc queue on redis $redis_url.');

    $log->debug("Sending ADD_WORKERS to rpc queue socket");
    $conn->write("ADD-WORKERS $redis_url\n");
    my $result = $conn->read_until("\n")->get;
    $log->debug("WORKERS response recieved: $result");

    return;
}

sub create_socket_connection {
    my $count = 0;
    while (not path($socket_path)->exists) {
        $count += 1;
        return undef if $count >= 5;
        sleep 1;
    }

    my $sock = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $socket_path,
    );

    unless ($sock) {
        $log->debug("Failed to establish connection to rpc queue socket: $socket_path");
        return undef;
    }

    my $loop = IO::Async::Loop->new;

    $loop->add(
        my $conn = IO::Async::Stream->new(
            handle  => $sock,
            on_read => sub { },    # entirely by Futures
        ));
    $log->debug("Connection established to rpc queue socket: $socket_path");
    return $conn;
}

sub stop_workers {
    my $conn = create_socket_connection();
    return unless $conn;
    my $result;
    $log->debug('Stopping workers of rpc queue through socket.');
    while (1) {
        $log->debug("Sending DEC_WORKERS to rpc queue socket");
        $conn->write("DEC-WORKERS\n");
        $result = $conn->read_until("\n")->get;
        $log->debug("Dec_workers response recieved: $result");
        last if ($result =~ / 0\n/);
    }
    return;
}

sub stop_service {
    stop_workers();
    my $conn = create_socket_connection();
    return unless $conn;

    my $attempts = 0;
    while (1) {
        $log->debug("Sending EXIT to rpc queue socket");
        $conn->write("EXIT\n");
        $conn->read_until("\n")->get;
        $log->debug("Exit response is recieved");
        last if not create_socket_connection();
        $attempts += 1;
        last if ($attempts > 5);
        sleep 1;
    }

    if ($attempts > 5) {
        $log->debug('RPC queue was not stopped in 5 seconds.');
    } else {
        $log->debug("RPC queue was stopped successfully");
    }

    return;
}

sub ping {
    my $conn = create_socket_connection();
    return 0 unless $conn;
    $log->debug('Sending PING command to rpc queue socket');
    $conn->write("PING\n");
    my $result = $conn->read_until("\n")->get;
    $log->debug("Ping response recieved: $result");
    return $result =~ /PONG/;
}

1;


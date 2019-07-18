package BOM::Test::Script::RpcQueue;
use strict;
use warnings;

use IO::Async::Stream;
use IO::Async::Loop;
use IO::Socket::UNIX;
use Path::Tiny;

use BOM::Test;
use BOM::Test::Script;

    my $socket = '/tmp/binary_jobqueue_worker.sock';
    my $script  = '/home/git/regentmarkets/bom-rpc/bin/binary_jobqueue_worker.pl';

sub new {
    my ($class, $redis_server) = @_;
    return bless {
        redis  => $redis_server,
    }, $class;
}


sub start {
    my $self = shift;
    $self->{redis}->url =~ /.*:(\d+)\D?$/;
    my $url = 'redis://127.0.0.1:' . $1;
    my $args  = "--testing --workers 1 --redis $url --socket $socket";
    system("$script $args &");
    warn 'RPC queue is not responding.' unless ping();
}

sub create_socket_connection{
    my $count = 0;
    while(not path($socket)->exists){
        $count += 1;
        return undef if $count >= 5;
        sleep 1;
    }
    
    my $sock = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $socket,
    );
    
    return undef unless $sock;
    
    my $loop = IO::Async::Loop->new; 

    $loop->add(
        my $conn = IO::Async::Stream->new(
            handle  => $sock,
            on_read => sub { },    # entirely by Futures
        ));
    return $conn;
}

sub stop{
    my $conn = create_socket_connection();
    return unless $conn;
        my $result;
        while (1){
            $conn->write("DEC-WORKERS\n");
            $result = $conn->read_until("\n")->get;
            last if ($result !~ / 0\n/);
        }
        $conn->write("EXIT\n");
}

sub ping{
    my $conn = create_socket_connection();
    return 0 unless $conn;
    $conn->write("PING\n");
    my $result = $conn->read_until("\n")->get;
    return $result =~ /PONG/;
}   

DESTROY{
    shift->stop;
    return;
}

1;


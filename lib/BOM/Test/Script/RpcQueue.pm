package BOM::Test::Script::RpcQueue;
use strict;
use warnings;

use IO::Async::Stream;
use IO::Async::Loop;
use IO::Socket::UNIX;
use Path::Tiny;
use Log::Any qw($log);

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
    $log->debug("RPC queue is launched with args: $args");
    
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
    
    unless ($sock)
    {
        $log->debug("Failed to establish connection to rpc queue socket: $socket");
        return undef;
    }
    
    my $loop = IO::Async::Loop->new; 

    $loop->add(
        my $conn = IO::Async::Stream->new(
            handle  => $sock,
            on_read => sub { },    # entirely by Futures
        ));
    $log->debug("Connection established to rpc queue socket: $socket");
    return $conn;
}

sub stop{
    my $conn = create_socket_connection();
    return unless $conn;
        my $result;
        $log->debug('Stopping workers of rpc queue through socket.');
        while (1){
            $log->debug("Sending DEC_WORKERS to rpc queue socket");
            $conn->write("DEC-WORKERS\n");
            $result = $conn->read_until("\n")->get;
            $log->debug("Dec_workers response recieved: $result");
            last if ($result =~ / 0\n/);
        }
        $log->debug("Sending EXIT to rpc queue socket");
        $conn->write("EXIT\n");
        $conn->read_until("\n")->get;
        $log->debug("Exit response is recievedaظ");
        
}

sub ping{
    my $conn = create_socket_connection();
    return 0 unless $conn;
    $log->debug('Sending PING command to rpc queue socket');
    $conn->write("PING\n");
    my $result = $conn->read_until("\n")->get;
    $log->debug("Ping response recieved: $result");
    return $result =~ /PONG/;
}   

DESTROY{
    $log->debug("Stopping rpc queue on object destruction");
    shift->stop;
    return;
}

1;


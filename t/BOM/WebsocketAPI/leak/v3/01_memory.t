use strict;
use warnings;

use Test::More;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use Test::NoLeaks;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Mojo::UserAgent;
use Mojo::IOLoop;
use Mojo::IOLoop::Delay;
use BOM::WebSocketAPI;
use Mojo::Server::Daemon;
use Net::EmptyPort qw/empty_port/;

initialize_realtime_ticks_db();

SKIP: {
    skip "need further investigation, why sometimes it reports memory leaks";

    my $port = empty_port;

    my $daemon = Mojo::Server::Daemon->new(
        app    => BOM::WebSocketAPI->new,
        listen => ["http://127.0.0.1:$port"],
    );
    $daemon->start;

#my $pass = 0;
    sub might_leak {
        my $ua = Mojo::UserAgent->new;
        #$pass++;
        #print("$pass\n");
        $ua->websocket(
            "ws://127.0.0.1:$port/websockets/v3" => sub {
                my ($ua2, $tx) = @_;
                BAIL_OUT('WebSocket handshake failed!') and return
                    unless $tx->is_websocket;
                $tx->once(
                    json => sub {
                        my ($tx, $hash) = @_;
                        BAIL_OUT("no active symbols")   unless $hash->{active_symbols};
                        BAIL_OUT("unexpected msg_type") unless $hash->{msg_type} eq 'active_symbols';
                        $tx->finish;
                        Mojo::IOLoop->stop;
                        #print("end\n");
                    });
                $tx->send({json => {active_symbols => 'brief'}});
                #print("end2\n");
            });
        Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
        Mojo::IOLoop->one_tick;
    }

    test_noleaks(
        code          => \&might_leak,
        track_memory  => 1,
        track_fds     => 1,
        passes        => 1024,
        warmup_passes => 1,
        tolerate_hits => 0,
    );

}
done_testing;

use strict;
use warnings;

use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema launch_redis build_mojo_test build_test_R_50_data/;
use Mojo::Transaction::HTTP;
use Devel::Refcount qw| refcount |;
use Mojo::IOLoop;
use Binary::WebSocketAPI::v3::Instance::Redis qw| pricer_write |;
use Parallel::ForkManager;
my $subs_count = 3;

build_test_R_50_data();

my $test_server = build_mojo_test('Binary::WebSocketAPI', {app_id => 1});

my %contractParameters = (
    "proposal"      => 1,
    "subscribe"     => 1,
    "amount"        => "10",
    "basis"         => "payout",
    "contract_type" => "PUT",
    "currency"      => "USD",
    "symbol"        => "R_50",
    "duration"      => "5",
    "duration_unit" => "h",
    "barrier"       => "+13.12",
);

$test_server->app->log(Mojo::Log->new(level => 'debug'));
my $endless_loop_avoid = 0;
my $url = '/websockets/v3?l=EN&debug=1&app_id=1';

my $channel;
my $user_first = {};

subtest "Born and die" => sub {

    my $t = $test_server->websocket_ok($url => {});

    $t->send_ok({
            json => {
                "proposal"  => 1,
                "subscribe" => 1,
                %contractParameters
            }})->message_ok;
    is(scalar keys %{$test_server->app->pricing_subscriptions()}, 1, "Subscription created");
    $channel = [keys %{$test_server->app->pricing_subscriptions()}]->[0];
    is(refcount($test_server->app->pricing_subscriptions()->{$channel}), 1, "check refcount");
    ok(pricer_write->get($channel), "check redis subscription");
    $t->send_ok({json => {forget_all => 'proposal'}})->message_ok;

    is($test_server->app->pricing_subscriptions()->{$channel}, undef, "Killed");
    ### Mojo::Redis2 has not method PUBSUB
    ok(!pricer_write->get($channel), "check redis subscription");

    $t->finish_ok;
};

my $server = $test_server->websocket_ok($url => {});
#$server->send_ok( {json => {forget_all => 'proposal'}})->message_ok;

=pod

my $port = $server->ua->server->url->port;
note $port;
$url = 'wss://localhost:'.$port.$url;
my @txs = ();
#my $ua = Mojo::UserAgent->new();
#for my $i (0 .. $subs_count-1) {
my $i = 0;


use IO::Async::Loop::Poll;
use Net::Async::WebSocket::Client;

my $client = Net::Async::WebSocket::Client->new(
    on_frame => sub {
        my ( $self, $frame ) = @_;
        note "CATCH";
        print $frame;
    },
);
note explain $client;
my $loop = IO::Async::Loop::Poll->new;
$loop->add( $client );
note explain $loop;
my $connect = $client->connect(
    url => $url,
)->then( sub {
             note "Send frame";
             $client->send_frame( '{"proposal":1}' )},
             sub { note "ERROR"; die "error"; }
         );

note "RUN";
note $connect->get;
note explain $connect;
$loop->run;

die;

=cut

=pod

sub subscribe {
    $ua->websocket( $url => sub {
                        my ( $ua, $tx ) = @_;

                        note "WebSocket handshake failed!\n" and return unless $tx->is_websocket;
                        $tx->on(json => sub {
                                    my ($tx, $hash) = @_;
                                    note $i++ ." --->> WebSocket message via JSON: $hash->{msg}";
                                    note (\$tx+0);
                                    my $tx1 = $ua->build_websocket_tx( $url );
                                    $ua->start($tx1 => sub {
                                                   my ($ua_i, $tx_i) = @_;
                                                   note "Start";

                                                   note 'WebSocket handshake failed!' and return unless $tx_i->is_websocket;
                                                   $tx->on(message => sub {
                                                               my ($tx, $msg) = @_;
                                                               note "WebSocket NEW message: $msg";
                                                               $tx_i->finish;
                                                               Mojo::IOLoop->stop;
                                                           });
                                                   $tx_i->send({
                                                       json => {
                                                           "proposal"  => 1,
                                                           "subscribe" => 1,
                                                           %contractParameters
                                                       }});
                                               });
                                    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
                                });
                        $tx->send(
                            {
                                json => {
                                    "proposal"  => 1,
                                    "subscribe" => 1,
                                    %contractParameters
                                }});
                    }
                );
    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}
subscribe();

=cut


subtest "Create Subscribes" => sub {

    my $future = Future->new();

    my $callback = sub {
        my ($tx, $msg) = @_;
#        if ( $endless_loop_avoid++ > 30 ) {
#            Mojo::IOLoop->stop;
#            $tx->finish;
#        }
        test_schema('proposal', decode_json $msg );

note $tx->req->cookie('user');

        $future->done( ) and $tx->finish if ($user_first->{$tx->req->cookie('user')->value} || 0) > 5;
        ### We need cookies for user identify
        return if $user_first->{$tx->req->cookie('user')->value}++;
        $user_first->{$tx->req->cookie('user')->value} = 1;
        $subs_count--;
        if ($subs_count == 0) {
            is(scalar keys %{$test_server->app->pricing_subscriptions()}, 1, "One subscription by few clients");
            $channel = [keys %{$test_server->app->pricing_subscriptions()}]->[0];
            is(refcount($test_server->app->pricing_subscriptions()->{$channel}), 3, "check refcount");
        }
    };
    my $i = 1;

    for my $i (0 .. $subs_count-1) {
        my $t_client = Test::Mojo->new;
        my $t = $test_server->websocket_ok($url => {});

        $t->tx->req->cookies({
                name  => 'user',
                value => ('#' . ++$i)});

        $t->tx->on(message => $callback);

        $t->send_ok({
                json => {
                    "proposal"  => 1,
                    "subscribe" => 1,
                    %contractParameters
                }})->message_ok;
    }

    $future->on_ready( sub {
                           note "The operation is complete " . shift;
    } );

};

my $total = 0;
map { $total += $_ } values %$user_first;

ok($total > $subs_count, "check streaming");

done_testing();

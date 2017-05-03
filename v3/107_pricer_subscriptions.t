use strict;
use warnings;

use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_mojo_test build_test_R_50_data/;

use Devel::Refcount qw| refcount |;
use Binary::WebSocketAPI::v3::Instance::Redis qw| redis_pricer |;

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
    ok(redis_pricer->get($channel), "check redis subscription");
    $t->send_ok({json => {forget_all => 'proposal'}})->message_ok;

    is($test_server->app->pricing_subscriptions()->{$channel}, undef, "Killed");
    ### Mojo::Redis2 has not method PUBSUB
    ok(!redis_pricer->get($channel), "check redis subscription");

    $t->finish_ok;
};

subtest "Create Subscribes" => sub {

    my $future = Future->new();

    my $callback = sub {
        my ($tx, $msg) = @_;

        test_schema('proposal', decode_json $msg );

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

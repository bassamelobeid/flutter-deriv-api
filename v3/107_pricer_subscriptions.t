use strict;
use warnings;

use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Devel::Refcount qw| refcount |;
use Test::MockModule;

use BOM::Test::Helper qw/test_schema build_mojo_test build_test_R_50_data/;
use Binary::WebSocketAPI::v3::Instance::Redis qw| redis_pricer |;

use await;

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
my $url                = '/websockets/v3?l=EN&debug=1&app_id=1';

my $channel;
my $user_first = {};

my $req_id = 0;

subtest "Born and die" => sub {

    my $t = $test_server->websocket_ok($url => {});

    $t->await::proposal({
        proposal => 1,
        req_id   => ++$req_id,
        %contractParameters
    });
    is(scalar keys %{$test_server->app->pricing_subscriptions()}, 1, "Subscription created");
    $channel = [keys %{$test_server->app->pricing_subscriptions()}]->[0];
    is(refcount($test_server->app->pricing_subscriptions()->{$channel}), 1, "check refcount");
    ok(redis_pricer->get($channel), "check redis subscription");
    $t->await::forget_all({
        forget_all => 'proposal',
        req_id     => ++$req_id,
    });

    is($test_server->app->pricing_subscriptions()->{$channel}, undef, "Killed");
    ### Mojo::Redis2 has not method PUBSUB
    SKIP: {
        skip 'Provide test access to pricing cycle so we can confirm that the subscription is cleaned up', 1;
        ok(!redis_pricer->get($channel), "check redis subscription");
    }

    $t->finish_ok;
};

subtest "Create Subscribes" => sub {

    my $callback = sub {
        my ($tx, $msg) = @_;

        test_schema('proposal', decode_json $msg );

        $user_first->{$tx->req->cookie('user')->value} = 1;
        if (--$subs_count == 0) {
            is(scalar keys %{$test_server->app->pricing_subscriptions()}, 1, "One subscription by few clients");
            $channel = [keys %{$test_server->app->pricing_subscriptions()}]->[0];
            is(refcount($test_server->app->pricing_subscriptions()->{$channel}), 3, "check refcount");
        }
    };

    my @connections;
    for my $i (0 .. $subs_count - 1) {
        my $t = $test_server->websocket_ok($url => {});
        push @connections, $t;

        $t->tx->req->cookies({
                name  => 'user',
                value => ('#' . $i)});

        $t->tx->on(message => $callback);

        $t->await::proposal({
            proposal => 1,
            req_id   => ++$req_id,
            %contractParameters
        });
    }

    cmp_ok(keys %$user_first, '==', 3, "3 subscription created ok");
    $test_server->await::forget_all({
        forget_all => 'proposal',
        req_id     => ++$req_id,
    });

    $_->finish_ok for @connections;

};

subtest "Count Subscribes" => sub {
    my $sets   = {};
    my $subscr = {};

    my $redis2_module = Test::MockModule->new('Mojo::Redis2');
    $redis2_module->mock(
        'set',
        sub {
            my ($redis, $channel_name, $value) = @_;
            $sets->{$channel_name}++;
        });
    $redis2_module->mock(
        'subscribe',
        sub {
            my ($redis, $channel_names, $callback) = @_;
            my $channel_name = shift @$channel_names;
            $subscr->{$channel_name}++;
        });

    my @connections;
    for my $i (0 .. 2) {
        my $t = $test_server->websocket_ok($url => {});
        push @connections, $t;
        my $res = $t->await::proposal({
            proposal => 1,
            req_id   => ++$req_id,
            %contractParameters,
            contract_type => "CALL",
        });
        test_schema('proposal', $res);
    }

    cmp_ok(keys %$sets,   '==', 1, "One key expected");
    cmp_ok(keys %$subscr, '==', 1, "One subscription expected");

    $redis2_module->unmock_all;
    $_->finish_ok for @connections;

};

done_testing();

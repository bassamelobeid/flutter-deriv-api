use strict;
use warnings;

use Test::Exception;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use Mojo::Redis2;

my $redis2_module = Test::MockModule->new('Mojo::Redis2');
my @commands_queue;
for my $command (qw/incrby expire/) {
    $redis2_module->mock($command, sub {
        push @commands_queue, [$command, @_];
    });
}
my %redis_storage;

my %redis_callbacks = (
    incrby => sub {
        my $mock = shift;
        my $key = shift;
        my $callback = pop;
        my $value = shift // 1;
        ($redis_storage{$key} //= 0) += $value;
        $callback->($mock, undef, $redis_storage{$key});
    },
    expire => sub {
        # no-op
    },
);
my $process_queue = sub {
    note "processing redis queue";
    while (@commands_queue) {
        my $command_data = shift @commands_queue;
        my $command = shift @$command_data;
        my $processor = $redis_callbacks{$command};
        die("No redis processor for '$command'")
            unless $processor;
        $processor->(@$command_data);
    }
};

use BOM::Test::Data::Utility::UnitTestRedis;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;

use Binary::WebSocketAPI::Hooks;

use JSON;
use Mojo::IOLoop::Delay;

my $t = build_wsapi_test();
my $c = $t->app->build_controller;

# stubs
$t->app->helper(app_id => sub { 1 });
$t->app->helper(rate_limitations_key => sub { "rate_limits::non-authorised::1/md5-hash-of-127.0.0.1" });

subtest "no limit for 'ping' or 'time'" => sub {
    my (@pings, @times);
    for (1 .. 500) {
        push @pings, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'ping', 0);
        push @times, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'time', 0);
    }
    lives_ok { Future->needs_all(@pings, @times)->get };
};

subtest "high real account buy sell pricing limit" => sub {
    my @futures;
    # 60 * 4 = 240, as in limits.yml
    for (1 .. 60) {
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'buy',                    1);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'sell',                   1);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal',               1);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal_open_contract', 1);
    }
    lives_ok { Future->needs_all(@futures)->get }, "no limits hit";

    dies_ok { Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal', 1)->get }, "limit hit";
};

subtest "hit limits 'proposal' / 'proposal_open_contract' for virtual account" => sub {
    my @futures;
    for (1 .. 60) {
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal',               0);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal_open_contract', 0);
    }

    dies_ok { Future->needs_all(@futures)->get }, "limit hit";
};

subtest "hit limits 'portfolio' / 'profit_table' for virtual account" => sub {
    my @futures;
    for (1 .. 30) {
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio',    0);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'profit_table', 0);
    }
    lives_ok { Future->needs_all(@futures)->get }, "no limits hit";

    dies_ok { Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0)->get }, "limit hit";
};

subtest "limits are persisted across connnections for the same client" => sub {
    $process_queue->();

    my $c2 = $t->app->build_controller;
    my $f = Binary::WebSocketAPI::Hooks::reached_limit_check($c2, 'portfolio', 0);
    lives_ok { $f->get }, "1st attempt is still allowed";

    $process_queue->();

    $f = Binary::WebSocketAPI::Hooks::reached_limit_check($c2, 'portfolio', 0);
    dies_ok { $f->get }, "but not any longer";
};

subtest "get error code (verify_email)" => sub {
    for (my $i = 0; $i < 4; $i++) {
        $t->send_ok({
                json => {
                    verify_email => '12asd',
                    type         => 'account_opening'
                }})->message_ok;
    }
    my $res = decode_json($t->message->[1]);
    is $res->{error}->{code}, 'RateLimit';
};

subtest "expiration of limits" => sub {
    # lets flush redis
    $process_queue->();
    %redis_storage = ();

    my $f1 = Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0);
    Mojo::IOLoop->one_tick while !$f1->is_ready;
    ok $f1->is_failed, "limit hit (we are still 1 step ahead of redis data)";
    # trigger updates of internals
    $process_queue->();

    my $f2 = Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0);
    Mojo::IOLoop->one_tick while !$f2->is_ready;
    ok $f2->is_done, "no limit hit";
};

$t->finish_ok;

done_testing();

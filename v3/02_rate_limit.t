use strict;
use warnings;

use Test::More;
use Test::Mojo;

use BOM::Test::Data::Utility::UnitTestRedis;
use Binary::WebSocketAPI::Hooks;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;

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
    my $f = Future->needs_all(@pings, @times);
    Mojo::IOLoop->one_tick while !$f->is_ready;
    ok $f->is_done;
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
    my $f = Future->needs_all(@futures);
    Mojo::IOLoop->one_tick while !$f->is_ready;
    ok $f->is_done, "no limits hit";

    $f = Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal', 1);
    Mojo::IOLoop->one_tick while !$f->is_ready;
    ok $f->is_failed, "limit hit";
};

subtest "hit limits 'proposal' / 'proposal_open_contract' for virtual account" => sub {
    my @futures;
    for (1 .. 60) {
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal',               0);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal_open_contract', 0);
    }
    my $f = Future->needs_all(@futures);
    Mojo::IOLoop->one_tick while !$f->is_ready;
    ok $f->is_failed;

};

subtest "hit limits 'portfolio' / 'profit_table' for virtual account" => sub {
    my @futures;
    for (1 .. 30) {
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio',    0);
        push @futures, Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'profit_table', 0);
    }
    my $f = Future->needs_all(@futures);
    Mojo::IOLoop->one_tick while !$f->is_ready;
    ok $f->is_done, "no limits hit";

    $f = Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0);
    Mojo::IOLoop->one_tick while !$f->is_ready;
    ok $f->is_failed, "limit hit";
};

subtest "limits are persisted across connnections for the same client" => sub {
    my $c2 = $t->app->build_controller;
    my $f = Binary::WebSocketAPI::Hooks::reached_limit_check($c2, 'portfolio', 0);
    Mojo::IOLoop->one_tick while !$f->is_ready;
    ok $f->is_failed, "limit hit";
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
    my $f1 = Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0);
    Mojo::IOLoop->one_tick while !$f1->is_ready;
    ok $f1->is_failed, "limit hit";

    note "let's wait expiration";
    Mojo::IOLoop::Delay->new->steps(
        sub {
            my $delay = shift;
            my $end = $delay->begin;
            my $t; $t = Mojo::IOLoop->timer(61 => sub {
                Mojo::IOLoop->remove($t);
                $end->();
            });
        }
    )->wait;
    my $f2 = Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio', 0);
    Mojo::IOLoop->one_tick while !$f2->is_ready;
    ok $f2->is_done, "no limit hit";
};

$t->finish_ok;

done_testing();

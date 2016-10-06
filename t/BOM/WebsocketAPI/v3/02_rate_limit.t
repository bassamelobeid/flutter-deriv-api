use strict;
use warnings;

use Test::More;
use Test::Mojo;

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::WebSocketAPI::Hooks;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/build_mojo_test/;

use JSON;
use Cache::RedisDB;

Cache::RedisDB->redis()->flushall();

# no limit for ping or time
for (1 .. 500) {
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'ping', 0));
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'time', 0));
}

# high real account buy sell pricing limit
for (1 .. 1320) {
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'buy',                    1));
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'sell',                   1));
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'proposal',               1));
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'proposal_open_contract', 1));
}

# proposal for the rest if limited
for (1 .. 1320) {
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'proposal', 0));
}
ok(BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'proposal', 0)) or die "here";

# porfolio is even more limited for the rest if limited
{
    my $i = 0;
    my $failed;
    while($i < 5000) {
        $failed = $_ for grep BOM::WebSocketAPI::Hooks::reached_limit_check(1, $_, 0), qw(portfolio profit_table);
        last if $failed;
        ++$i;
    }
    is($i, 660, 'rate limiting for portfolio happened after expected number of iterations');
}
ok(BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'portfolio',    0));
ok(BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'profit_table', 0));

# portfolio for connection number 1 is limited but then if it is another connections (number 2), it goes OK.
ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(2, 'profit_table', 0));

Cache::RedisDB->redis()->flushall();

my $t = build_mojo_test();
my $res;
for (my $i = 0; $i < 4; $i++) {
    $t->send_ok({
            json => {
                verify_email => '12asd',
                type         => 'account_opening'
            }})->message_ok;
}
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'RateLimit';

{
    my $res2;
    my $i = 0;
    while($i < 10000) {
        $t->tx->send({
            json => {
                payout_currencies => 1 
            }
        }, sub { Mojo::IOLoop->stop });
        Mojo::IOLoop->start;
        note "still waiting after $i iterations" unless $i % 100;
        $res2 = decode_json($t->_wait->[1]);
        last if $res2->{error};
        ++$i;
    }
    TODO: {
        # So on QA, both of these pass, but Travis consistently fails to hit the limit, works as expected when reducing the limit
        # so it seems to be just due to slower performance
        local $TODO = 'Travis run is too slow for the rate limit to trigger, the minute expires before the rate limit kicks in';
        is $res2->{error}->{code}, 'RateLimit';
        is $i, 5280, "RateLimit for payout_currencies happened after expected number of iterations";
    }
}

$t->finish_ok;

done_testing();

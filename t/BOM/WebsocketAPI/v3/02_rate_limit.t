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
for (1 .. 60) {
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'buy',                    1));
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'sell',                   1));
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'proposal',               1));
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'proposal_open_contract', 1));
}

# proposal for the rest if limited
for (1 .. 60) {
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'proposal', 0));
}
ok(BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'proposal', 0));

# porfolio is even more limited for the rest if limited
for (1 .. 30) {
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'portfolio',    0));
    ok(not BOM::WebSocketAPI::Hooks::reached_limit_check(1, 'profit_table', 0));
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

my $res2;
for (my $i = 0; $i < 4; $i++) {
    $t->send_ok({
            json => {
                payout_currencies => 1, 
            }})->message_ok;
}
$res2 = decode_json($t->message->[1]);
is $res2->{error}->{code}, 'RateLimit';

$t->finish_ok;

done_testing();

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

my $t = build_wsapi_test();
my $c = $t->app->build_controller;
# no limit for ping or time
for (1 .. 500) {
    ok(not Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'ping', 0));
    ok(not Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'time', 0));
}

# high real account buy sell pricing limit
for (1 .. 60) {
    ok(not Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'buy',                    1));
    ok(not Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'sell',                   1));
    ok(not Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal',               1));
    ok(not Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal_open_contract', 1));
}

# proposal for the rest if limited
for (1 .. 60) {
    ok(not Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal', 0));
}
ok(Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'proposal', 0)) or die "here";

# porfolio is even more limited for the rest if limited
{
    my $i = 0;
    my $failed;
    while ($i < 100) {
        $failed = $_ for grep Binary::WebSocketAPI::Hooks::reached_limit_check($c, $_, 0), qw(portfolio profit_table);
        last if $failed;
        ++$i;
    }
    is($i, 30, 'rate limiting for portfolio happened after expected number of iterations');
}
ok(Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'portfolio',    0));
ok(Binary::WebSocketAPI::Hooks::reached_limit_check($c, 'profit_table', 0));

# portfolio for connection number 1 is limited but then if it is another connections (number 2), it goes OK.
# for new controller/user we'll have new stash, hence check should pass
my $c2 = $t->app->build_controller;
ok(not Binary::WebSocketAPI::Hooks::reached_limit_check($c2, 'profit_table', 0));

# rate-limits are loaded/saved asynchronously, so, let's wait a bit
Mojo::IOLoop->one_tick for(1 .. 2);

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
    while ($i < 500) {
        $t->tx->send({json => {payout_currencies => 1}}, sub { Mojo::IOLoop->stop });
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
        is $i, 240, "RateLimit for payout_currencies happened after expected number of iterations";
    }
}

$t->finish_ok;

done_testing();

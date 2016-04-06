use strict;
use warnings;
use Test::More;

use BOM::WebSocketAPI::Websocket_v3;

use BOM::Test::Data::Utility::UnitTestRedis;
use Cache::RedisDB;
Cache::RedisDB->redis()->flushall();

# no limit for ping or time
for (1 .. 500) {
    ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'ping', 0));
    ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'time', 0));
}

# high real account buy sell pricing limit
for (1 .. 60) {
    ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'buy',                    1));
    ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'sell',                   1));
    ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'proposal',               1));
    ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'proposal_open_contract', 1));
}

# proposal for the rest if limited
for (1 .. 60) {
    ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'proposal', 0));
}
ok(BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'proposal', 0));

# porfolio is even more limited for the rest if limited
for (1 .. 30) {
    ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'portfolio',    0));
    ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'profit_table', 0));
}
ok(BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'portfolio',    0));
ok(BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(1, 'profit_table', 0));

# portfolio for connection number 1 is limited but then if it is another connections (number 2), it goes OK.
ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check(2, 'profit_table', 0));

done_testing();

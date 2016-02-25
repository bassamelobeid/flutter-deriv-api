use strict;
use warnings;
use Test::More;

use BOM::WebSocketAPI::Websocket_v3;

# no limit for ping or time
for (1..500) {
	ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('ping', 0));
	ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('time', 0));
}

# real account wont have buy limit
for (1..500) {
	ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('buy', 1));
	ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('sell', 1));
	ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('proposal', 1));
	ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('proposal_open_contract', 1));
}

# proposal for the rest if limited
for (1..60) {
	ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('proposal', 0));
}
ok(BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('proposal', 0));

# porfolio is even more limited for the rest if limited
for (1..10) {
	ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('porfolio', 0));
	ok(not BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('profit_table', 0));
}
ok(BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('porfolio', 0));
ok(BOM::WebSocketAPI::Websocket_v3::_reached_limit_check('profit_table', 0));


done_testing();

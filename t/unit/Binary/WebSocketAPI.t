use strict;
use warnings;
use Test::More;

use Binary::WebSocketAPI;

subtest check_blocked_app_id => sub {

    is_deeply([1], Binary::WebSocketAPI::APPS_BLOCKED_FROM_OPERATION_DOMAINS->{red}, "APP ID 1 is blocked on RED");
    is_deeply(
        [24269, 23650, 19499],
        Binary::WebSocketAPI::APPS_BLOCKED_FROM_OPERATION_DOMAINS->{blue},
        "APP IDs 24269, 23650, 19499 are blocked on BLUE"
    );
};

done_testing;

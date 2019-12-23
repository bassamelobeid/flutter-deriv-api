use strict;
use warnings;

use Test::More;

use Binary::WebSocketAPI;

ok(!$INC{"Future/AsyncAwait.pm"}, 'Future::AsyncAwait is not loaded');

done_testing;

use strict;
use warnings;

use Test::More;

use BOM::RPC::Transport::HTTP;

ok(!$INC{"Future/AsyncAwait.pm"}, 'Future::AsyncAwait is not loaded');

done_testing;

use strict;
use warnings;

use Test::More;

ok(!$INC{"Future/AsyncAwait.pm"}, 'Future::AsyncAwait is not loaded');

done_testing;

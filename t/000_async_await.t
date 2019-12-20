use strict;
use warnings;

use Test::More;

# Load some of the modules - this is not an exhaustive test yet
do './bom-backoffice.psgi';

ok(!$INC{"Future/AsyncAwait.pm"}, 'Future::AsyncAwait is not loaded');

done_testing;

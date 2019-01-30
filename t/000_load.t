use Test::More;
use strict;
use warnings;

use Test::Fatal;

is(exception { require Binary::WebSocketAPI; Binary::WebSocketAPI->import }, undef, 'can load module without issues')
    or note "module load failure: $@";

done_testing;

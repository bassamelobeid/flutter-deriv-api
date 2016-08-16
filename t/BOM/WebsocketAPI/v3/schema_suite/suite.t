use strict;
use warnings;
use Test::Most;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";

use Suite;

Suite->run('suite.conf');
done_testing();


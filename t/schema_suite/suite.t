use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite;

my $dir_path = __DIR__;
BOM::Test::Suite->run({
    test_app          => 'BOM::RPC',
    test_conf_path    => $dir_path . "/$ARGV[0]",
    suite_schema_path => $dir_path . '/config/',
});
done_testing();


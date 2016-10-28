use strict;
use warnings;
use Test::Most;
use File::Spec;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite;

my (undef, $file_path, undef) = File::Spec->splitpath(__FILE__);
BOM::Test::Suite->run({
    test_conf_path => $file_path . 'suite.conf',
    suite_schema_path => $file_path,
});
done_testing();


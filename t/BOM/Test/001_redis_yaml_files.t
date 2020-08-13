use strict;

use BOM::Test;

use Test::More;
use List::MoreUtils qw(uniq);
use File::Basename;

if (BOM::Test::on_qa) {
    my @redis_configs_paths = uniq map { $ENV{$_} } grep { $_ =~ qr/^BOM_TEST_REDIS/ } keys %ENV;

    for my $path (@redis_configs_paths) {
        my $name   = basename $path;
        my $exists = -e $path;
        ok $exists, "File '$name' exists in configs directory";
    }

} else {
    ok 1, "Tests skipped because weren't in QA environment.";
}
done_testing;

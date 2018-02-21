use strict;
use warnings;

use Test::More;
use Test::Vars;

subtest 'unused vars' => sub {

    # These 2 files are not complete modules. So it will report error when processing them. Skip it for now
    my %skipped_files = (
        'lib/BOM/Product/ContractValidator.pm' => 1,
        'lib/BOM/Product/ContractVol.pm'       => 1,
        'lib/BOM/Product/ContractPricer.pm'    => 1,
    );
    for my $file (qx{git ls-files lib}) {
        chomp $file;
        if (-f $file and $file =~ /\.pm$/ and not $skipped_files{$file}) {
            vars_ok $file;
        }
    }
    done_testing;
};
done_testing;


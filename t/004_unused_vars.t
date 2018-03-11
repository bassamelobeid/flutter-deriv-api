use strict;
use warnings;

use Test::More;
use Test::Vars;

subtest 'unused vars' => sub {

    for my $file (qx{git ls-files lib}) {
        chomp $file;
        if (-f $file and $file =~ /\.pm$/) {
            vars_ok $file;
        }
    }
    done_testing;
};
done_testing;


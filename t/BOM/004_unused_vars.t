use strict;
use warnings;

use Test::More;
use Test::Vars;

subtest 'unused vars' => sub {
    for my $file (qx{git ls-files lib}) {
        chomp $file;
        vars_ok $file if -f $file and $file =~ /\.pm$/;
    }
    done_testing;
};
done_testing;


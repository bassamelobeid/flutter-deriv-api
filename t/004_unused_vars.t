use strict;
use warnings;

use Dir::Self;
use lib __DIR__ . '/..';
use Test::More;
use Test::Vars;

subtest 'unused vars' => sub {
    for my $file (qx{git ls-files lib}) {
        chomp $file;
        vars_ok $file, ignore_vars => ['$guard_scope'] if -f $file and $file =~ /\.pm$/;
    }
    done_testing;
};
done_testing;


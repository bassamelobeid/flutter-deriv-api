#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use BOM::Test;
use Test::Exception;
use Data::Dumper;

use Test::MockModule;
use BOM::CompanyLimits::Helpers;

subtest 'key combination test', sub {
    my @a     = qw/a/;
    my @limit = BOM::CompanyLimits::Helpers::get_all_key_combinations(@a);
    is_deeply(\@limit, ['a',], 'Single element array returns itself');

    @a     = qw/a b/;
    @limit = BOM::CompanyLimits::Helpers::get_all_key_combinations(@a);
    is_deeply(\@limit, ['a,', ',b', 'a,b'], '2 elements');

    @a     = qw/a b c d/;
    @limit = BOM::CompanyLimits::Helpers::get_all_key_combinations(@a);
    is_deeply(\@limit,
        ['a,,,', ',b,,', 'a,b,,', ',,c,', 'a,,c,', ',b,c,', 'a,b,c,', ',,,d', 'a,,,d', ',b,,d', 'a,b,,d', ',,c,d', 'a,,c,d', ',b,c,d', 'a,b,c,d'],
        '4 elements');

};

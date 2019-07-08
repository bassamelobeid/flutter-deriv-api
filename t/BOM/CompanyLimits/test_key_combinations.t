#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use BOM::Test;
use Test::Exception;
use Data::Dumper;

use Test::MockModule;
use BOM::CompanyLimits::Limits::Helpers;

subtest 'key combination test', sub {
    my @limit = BOM::CompanyLimits::Limits::_add_limit_value(10000, 1561801504, 1561801810);
    is_deeply (\@limit, [10000, 1561801504, 1561801810], 'first limit, return itself');

    @limit = BOM::CompanyLimits::Limits::_add_limit_value(10, 0, 0, @limit);
    is_deeply (\@limit, [10, 0, 0, 10000, 1561801504, 1561801810], 'smallest limit, inserted into front');

};

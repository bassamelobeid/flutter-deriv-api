use strict;
use warnings;

use Test::More;
use Test::Fatal;

use BOM::Platform::Script::MonthlyClientReport;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

is(
    exception {
        BOM::Platform::Script::MonthlyClientReport::run()
    },
    undef,
    'can run monthly client report without encountering exceptions'
);

done_testing;


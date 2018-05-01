use strict;
use warnings;

use Test::More;
use Test::Fatal;

use BOM::Platform::Script::MonthlyClientReport;

is(exception {
    BOM::Platform::Script::MonthlyClientReport::run()
}, undef, 'can run monthly client report without encountering exceptions');

done_testing;



#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;

# This is here only to save time by resetting the test database once here for a run of prove t/*.t.
# Unless it's been really scrambled, there's no need to reset it at the top of each paymentapi test.

if ($ENV{SKIP_TESTDB_INIT}) {
    require BOM::Test::Data::Utility::UnitTestDatabase;
    BOM::Test::Data::Utility::UnitTestDatabase->import(':init');
    ok(1, 'test database has been reset up-front for whole test-suite');
} else {
    ok(1, 'test database will be reset in each test.  To avoid, set SKIP_TESTDB_INIT');
}

done_testing();

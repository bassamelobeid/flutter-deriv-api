use strict;
use warnings;

use Test::Most;
use BOM::Test::CheckUsage;

# Note, this test is to discourage further user of the specific patterns to
# encourage usage of the BOM::Test::Customer pattern for user/client creation.
# At its simplest its just this to create a user/client pair
#
#     my $test_customer = BOM::Test::Customer->create(
#         residence => 'id',
#         clients   => [{
#                 name        => 'CR',
#                 broker_code => 'CR',
#             }]);
#     my $client_copy = $test_customer->get_client_object('CR');
#

my $repo     = 'bom-user/t';
my $type     = "*.t";
my $package  = 'BOM::Test::Data::Utility::UnitTestDatabase::create_client';
my $usage    = BOM::Test::CheckUsage::check_count($repo, $type, $package);
my $expected = 191;
is($usage, $expected, "Usage of '$package' pattern in '$repo/$type' matches expectations of $expected usages");

if ($usage > $expected) {
    diag("\nPlease do not increase the usage count for $package, ");
    diag("instead please use the BOM::Test::Customer pattern for user/client creation\n\n");
    diag("    my \$test_customer = BOM::Test::Customer->create(");
    diag("         residence => 'id',");
    diag("         clients   => [{");
    diag("                 name        => 'CR',");
    diag("                 broker_code => 'CR',");
    diag("             }]);");
    diag("    my \$client_copy = \$test_customer->get_client_object('CR');\n\n");
}
if ($usage < $expected) {
    diag("\nThank you for lowering the usage count for $package");
    diag("\nPlease edit " . __FILE__ . " and reduce the expected usage count to $usage\n\n");
}

done_testing();

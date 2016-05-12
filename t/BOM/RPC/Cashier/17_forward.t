use strict;
use warnings;
use Test::More;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/create_test_user/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;

my $client = create_test_user();

my $res = BOM::RPC::v3::Cashier::cashier({
    client  => $client,
    cashier => 'deposit'
});
is $res->{error}->{code}, 'ASK_TNC_APPROVAL';

done_testing();

use strict;
use warnings;
use Test::More;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/create_test_user/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::MockModule;
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;

my $test_loginid = create_test_user();
my $token = 'blabla';
my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
$mock_utility->mock('get_token_details', sub { return {loginid => $test_loginid} });

my $res = BOM::RPC::v3::Cashier::cashier({
    token => $token,
    cashier => 'deposit'
});
is $res->{error}->{code}, 'ASK_TNC_APPROVAL';

# BOM::RPC::v3::Accounts::tnc_approval({token => $token});
# $res = BOM::RPC::v3::Cashier::cashier({
#     token => 'blabla',
#     cashier => 'deposit'
# });
# print Dumper(\$res); use Data::Dumper;

done_testing();

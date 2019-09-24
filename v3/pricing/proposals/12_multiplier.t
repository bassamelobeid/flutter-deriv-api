use strict;
use warnings;
use Test::More;
use Test::Deep;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use await;

build_test_R_50_data();
my $t = build_wsapi_test();
my $empty_proposal = $t->await::proposal({proposal => 1});
is($empty_proposal->{error}->{code}, 'InputValidationFailed');

my $req = {
    "proposal"      => 1,
    "amount"        => "100",
    "basis"         => "payout",
    "currency"      => "USD",
    "contract_type" => "MULTUP",
    "symbol"        => "R_50",
};

my $res = $t->await::proposal($req);
ok $res->{error}, 'proposal error';
is $res->{error}->{code}, 'ContractCreationFailure', 'error code ContractCreationFailure';
is $res->{error}->{message}, 'Basis must be stake for this contract.', 'message \'Basis must be stake for this contract.\'';

$req->{basis} = 'stake';
$res = $t->await::proposal($req);
ok $res->{error}, 'proposal error';
is $res->{error}->{code}, 'ContractCreationFailure', 'error code ContractCreationFailure';
is $res->{error}->{message}, 'Missing required contract parameters (multiplier).', 'message \'Missing required contract parameters (multiplier).\'';

$req->{multiplier} = 5;
$req->{duration} = 60;
$req->{duration_unit} = 's';
$res = $t->await::proposal($req);
ok $res->{error}, 'proposal error';
is $res->{error}->{code}, 'ContractCreationFailure', 'error code ContractCreationFailure';
is $res->{error}->{message}, 'Invalid input (duration or date_expiry) for this contract type (MULTUP).', 'message \'Invalid input (duration or date_expiry) for this contract type (MULTUP).\'';

delete $req->{duration};
delete $req->{duration_unit};

$req->{barrier} = 100;
$res = $t->await::proposal($req);
ok $res->{error}, 'proposal error';
is $res->{error}->{code}, 'ContractCreationFailure', 'error code ContractCreationFailure';
is $res->{error}->{message}, 'Barrier is not allowed for this contract type.', 'message \'Barrier is not allowed for this contract type.\'';

delete $req->{barrier};
$res = $t->await::proposal($req);
ok $res->{proposal}->{id}, 'Should return id';
done_testing;

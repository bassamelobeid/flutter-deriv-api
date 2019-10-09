use strict;
use warnings;
use Test::More;
use Test::Deep;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;
use Data::Dumper;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

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

$req->{multiplier}    = 5;
$req->{duration}      = 60;
$req->{duration_unit} = 's';
$res                  = $t->await::proposal($req);
ok $res->{error}, 'proposal error';
is $res->{error}->{code}, 'ContractCreationFailure', 'error code ContractCreationFailure';
is $res->{error}->{message}, 'Invalid input (duration or date_expiry) for this contract type (MULTUP).',
    'message \'Invalid input (duration or date_expiry) for this contract type (MULTUP).\'';

delete $req->{duration};
delete $req->{duration_unit};

$req->{barrier} = 100;
$res = $t->await::proposal($req);
ok $res->{error}, 'proposal error';
is $res->{error}->{code}, 'ContractCreationFailure', 'error code ContractCreationFailure';
is $res->{error}->{message}, 'Barrier is not allowed for this contract type.', 'message \'Barrier is not allowed for this contract type.\'';

delete $req->{barrier};
$res = $t->await::proposal($req);
ok $res->{error}, 'proposal error';
is $res->{error}->{code}, 'ContractCreationFailure', 'error code ContractCreationFailure';
is $res->{error}->{message}, 'Multiplier is not in acceptable range. Accepts 20,40,60,100,200.',
    'message \'Multiplier is not in acceptable range. Accepts 20,40,60,100,200.\'';

$req->{multiplier} = 20;
$res = $t->await::proposal($req);

if (my $proposal = $res->{proposal}) {
    ok $proposal->{id}, 'Should return id';
    ok $proposal->{barriers}->{stop_out}, 'has stop out';
    ok $proposal->{barriers}->{stop_out}->{barrier_value}, 'has stop out barrier value';
    ok $proposal->{barriers}->{stop_out}->{display_name},  'has stop out display_name';
} else {
    diag Dumper($res);
}

$req->{limit_order} = {
    take_profit => 1,
};
$res = $t->await::proposal($req);

if (my $proposal = $res->{proposal}) {
    ok $proposal->{id}, 'Should return id';
    ok $proposal->{barriers}->{stop_out}, 'has stop out';
    ok $proposal->{barriers}->{stop_out}->{barrier_value}, 'has stop out barrier value';
    ok $proposal->{barriers}->{stop_out}->{display_name},  'has stop out display_name';
    ok $proposal->{barriers}->{take_profit}, 'has take profit';
    ok $proposal->{barriers}->{take_profit}->{barrier_value}, 'has take profit barrier value';
    ok $proposal->{barriers}->{take_profit}->{display_name},  'has take profit display_name';
} else {
    diag Dumper($res);
}

$req->{limit_order} = {
    take_something => 10,
};
$res = $t->await::proposal($req);
ok $res->{error}, 'proposal error';
is $res->{error}->{code}, 'InputValidationFailed', 'error code InputValidationFailed';
is $res->{error}->{message}, 'Input validation failed: limit_order', 'message \'Input validation failed: limit_order\'';

delete $req->{limit_order};
$req->{symbol} = 'frxUSDJPY';
$res = $t->await::proposal($req);
ok $res->{error}, 'proposal error';
is $res->{error}->{code}, 'OfferingsValidationError', 'error code OfferingsValidationError';
is $res->{error}->{message}, 'Trading is not offered for this asset.', 'message \'Trading is not offered for this asset.\'';
done_testing;

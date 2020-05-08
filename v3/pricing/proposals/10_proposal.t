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
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Database::DataMapper::FinancialMarketBet;

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
    "contract_type" => "CALL",
    "symbol"        => "R_100",
    "duration"      => "1",
    "duration_unit" => "m"
};

my $res = $t->await::proposal($req);
ok $res->{proposal}->{id}, 'Should return id';

$req->{amount} = "70e-2";
$res = $t->await::proposal($req);
ok $res->{proposal}->{id}, 'Should return id for exponential number';

#test wrong amount value
$req->{amount} = ".";
$res = $t->await::proposal($req);
is $res->{error}->{code}, 'InputValidationFailed', 'Correct failed due to input validation';

#test Special wrong amount values
my @special_numbers = qw(NaN -NaN inf -inf);
foreach my $special_number (@special_numbers) {
    $req->{amount} = $special_number;
    $res = $t->await::proposal($req);
    is $res->{error}->{code}, 'InputValidationFailed', "Correct failed due to input: $special_number validation";
}

$req->{amount} = "+100";
$res = $t->await::proposal($req);
is $res->{error}->{code}, undef, 'Correct + sign in number, allowed due to coercion';

$req->{duration} = "10000000000";
$res = $t->await::proposal($req);
is $res->{error}->{code}, 'InputValidationFailed', 'Schema validation fails with huge duration';

$req->{duration} = "99999999";
$res = $t->await::proposal($req);
is $res->{error}->{code}, 'ContractCreationFailure', 'Duration validation fails with huge duration';

delete $req->{duration};
$req->{date_expiry} = 9999999999;
$res = $t->await::proposal($req);
is $res->{error}->{code}, 'ContractCreationFailure', 'Duration validation fails with huge duration';
delete $req->{date_expiry};

$req->{duration} = "-10";
$res = $t->await::proposal($req);
is $res->{error}->{code}, 'InputValidationFailed', 'Schema validation fails with negative duration';

$req->{duration} = "1";
$req->{barrier}  = "10.0000000000000000000000000000000000000";
$res             = $t->await::proposal($req);
is $res->{error}->{code},    'InputValidationFailed',            'Schema validation fails with invalid barrier';
is $res->{error}->{message}, 'Input validation failed: barrier', 'Schema validation fails and returns correct message';

done_testing;

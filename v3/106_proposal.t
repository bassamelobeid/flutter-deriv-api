use strict;
use warnings;
use Test::More;
use Test::Deep;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;
use Data::Dumper;
use Try::Tiny;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Database::DataMapper::FinancialMarketBet;

build_test_R_50_data();
my $t = build_wsapi_test();
$t = $t->send_ok({json => {proposal => 1}})->message_ok;
my $empty_proposal = decode_json($t->message->[1]);
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

$t->send_ok({json => $req})->message_ok;
my $res = decode_json($t->message->[1]);
ok $res->{proposal}->{id}, 'Should return id';

$req->{amount} = "70e-2";
$t->send_ok({json => $req})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{proposal}->{id}, 'Should return id for exponential number';

#test wrong amount value
$req->{amount} = ".";
$t->send_ok({json => $req})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'InputValidationFailed', 'Correct failed due to input validation';

$req->{amount} = "+100";
$t->send_ok({json => $req})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'InputValidationFailed', 'Correct failed due to + sign in number, not allowed as per json schema';

done_testing;

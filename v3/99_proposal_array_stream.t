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
use BOM::System::RedisReplicated;
use BOM::Database::DataMapper::FinancialMarketBet;

build_test_R_50_data();
my $t = build_wsapi_test();
$t = $t->send_ok({json => {proposal_array => 1}})->message_ok;
my $empty_proposal_open_contract = decode_json($t->message->[1]);
is($empty_proposal_open_contract->{error}{details}{barriers}, 'is missing and it is required');

my $req = {
    "proposal_array" => 1,
    "subscribe"      => 1,
    "amount"         => "100",
    "basis"          => "payout",
    "currency"       => "USD",
    "contract_type"  => "CALL",
    "symbol"         => "R_100",
    "duration"       => "1",
    "duration_unit"  => "m",
    "barriers"       => [{"barrier" => "+1"}, {"barrier" => "+2"}]};

my $res;

$t->send_ok({json => $req})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{proposal_array}->{id}, 'Should return id';

$req->{req_id} = 1;
$t->send_ok({json => $req})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{proposal_array}->{id}, 'Should return id';

$t->send_ok({json => $req})->message_ok;
$res = decode_json($t->message->[1]);

is $res->{error}->{code}, 'AlreadySubscribed', 'Correct error for already subscribed with same req_id';

$t->send_ok({json => {forget_all => 'proposal'}})->message_ok;
$res = decode_json($t->message->[1]);
is scalar @{$res->{forget_all}}, 2, 'Correct number of subscription forget';

done_testing;

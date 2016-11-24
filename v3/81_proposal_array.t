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

my $sent_json =
  {
   "proposal_array"=> 1,
   "amount"=> "100",
   "basis"=> "payout",
   "currency"=> "USD",
   "contract_type"=> "CALL",
   "symbol"=> "R_50",
   "duration"=> "10",
   "duration_unit"=> "t",
   "barriers"=> [
                {
                 "barrier"=> "0"
                },
                {
                 "barrier"=> "1"
                }
               ]
  };

$t = $t->send_ok({json => $json});
$t = $t->message_ok;
$res = decode_json($t->message->[1]);
diag(Dumper($res));

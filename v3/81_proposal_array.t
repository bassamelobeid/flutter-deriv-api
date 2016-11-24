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
   "symbol"=> "R_100",
   "duration"=> "1",
   "duration_unit"=> "m",
   "barriers"=> [
                {
                 "barrier"=> "+1"
                },
                {
                 "barrier"=> "+2"
                }
               ]
  };

my @res;
$t = $t->send_ok({json => $sent_json});
$t = $t->message_ok;
push @res, decode_json($t->message->[1]);
$t = $t->message_ok;
push @res, decode_json($t->message->[1]);
@res = sort {$a->{echo_req}{barrier} cmp $b->{echo_req}{barrier}} @res;
for (0..1){
  is($res[$_]{echo_req}{barrier}, $sent_json->{barriers}[$_]{barrier}, 'barrier correct');
  is($res[$_]{echo_req}{proposal}, "1", "ws command should be a proposal");
  is($res[$_]{msg_type}, 'proposal', "message type should be proposal");
  is($res[$_]{proposal}{longcode}, "Win payout if Volatility 100 Index is strictly higher than entry spot plus $sent_json->{barriers}[$_]{barrier}.00 at 1 minute after contract start time." );
}
done_testing;

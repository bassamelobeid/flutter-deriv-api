use strict;
use warnings;

use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::Product;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $loginid = $client->loginid;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $loginid,
    email   => $email
)->token;

$client->deposit_virtual_funds;
my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);


subtest 'sell' => sub {
      my $params = {
                    language => 'ZH_CN',
                    token    => 'invalid token'
                   };
      $c->call_ok('sell', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token')
        ->error_message_is('令牌无效。', 'invalid token');

      $params->{token} = $token;

      $client->set_status('disabled', 1, 'test');
      $client->save;
      $c->call_ok('sell', $params)->has_no_system_error->has_error->error_code_is('DisabledClient', 'disabled client')
        ->error_message_is('此账户不可用。', 'account disabled');

      $client->clr_status('disabled');
      $client->save;

      #sold  contract should be hold 2 minutes and interval should more than 15
      my $contract = BOM::Test::Data::Utility::Product::create_contract(start_time => time - 60 * 2, interval => '20m');
      ok($contract);

      my $buy_params = {language => 'ZH_CN', token => $token};
      $buy_params->{source}              = 1;
      $buy_params->{contract_parameters} = {
                                        "proposal"      => 1,
                                        "amount"        => "100",
                                        "basis"         => "payout",
                                        "contract_type" => "CALL",
                                        "currency"      => "USD",
                                        "duration"      => "20",
                                        "duration_unit" => "m",
                                        "symbol"        => "R_50",
                                       };

      $buy_params->{args}{price} = $contract->ask_price;
      my $buy_result = $c->call_ok('buy', $buy_params)->has_no_system_error->result;

      $params->{source} = 1;
      $params->{args}{sell} = $buy_result->{contract_id};
      diag Dumper $c->call_ok('sell', $params)->has_no_system_error->has_no_error->result;
};

done_testing();

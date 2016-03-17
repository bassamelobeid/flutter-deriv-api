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
subtest 'buy' => sub {
    my $params = {language => 'ZH_CN', token => 'invalid token'};
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token')
        ->error_message_is('令牌无效。', 'invalid token');

    $params->{token} = $token;

    #I don't know how to set such a scenario that a valid token id have no valid client,
    #So I mock client module to simulate this scenario.
    my $mocked_client = Test::MockModule->new('BOM::Platform::Client');
    $mocked_client->mock('new',sub {return undef});
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'AuthorizationRequired')
      ->error_message_is('请登陆。', 'please login');
    undef $mocked_client;

    $params->{contract_parameters} = {};
    {
      local $SIG{'__WARN__'} = sub {
        my $msg = shift;
        if ($msg !~ /Use of uninitialized value in pattern match/) {
          print STDERR $msg;
        }
      };
      $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'ContractCreationFailure')
        ->error_message_is('无法创建合约', 'cannot create contract');

    }

    my $contract = BOM::Test::Data::Utility::Product::create_contract();

    $params->{source} = 1;
    $params->{contract_parameters} = {
                                      "proposal"      => 1,
                                      "amount"        => "100",
                                      "basis"         => "payout",
                                      "contract_type" => "CALL",
                                      "currency"      => "USD",
                                      "duration"      => "120",
                                      "duration_unit" => "s",
                                      "symbol"        => "R_50",
                                     };
    my $result = $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('PriceMoved', 'price moved error');
    #like($result->{error}{message_to_client}, qr/自从您为交易定价后，标的市场已发生太大变化/, 'price moved error');
    diag Dumper $c->call_ok('buy', $params)->has_no_system_error->has_error->response;

    $params->{args}{price} = $contract->stake;
    diag Dumper $c->call_ok('buy', $params)->has_no_system_error->has_error->response;
};

done_testing();

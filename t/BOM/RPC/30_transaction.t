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
subtest 'buy' => sub {
    my $params = {
        language => 'ZH_CN',
        token    => 'invalid token'
    };
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token')
        ->error_message_is('令牌无效。', 'invalid token');

    $params->{token} = $token;

    #I don't know how to set such a scenario that a valid token id have no valid client,
    #So I mock client module to simulate this scenario.
    my $mocked_client = Test::MockModule->new('BOM::Platform::Client');
    $mocked_client->mock('new', sub { return undef });
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

    $params->{source}              = 1;
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
    my $result = $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('PriceMoved', 'price moved error')->result;
    like($result->{error}{message_to_client}, qr/自从您为交易定价后，标的市场已发生太大变化/, 'price moved error');

    $params->{args}{price} = $contract->ask_price;
    my $old_balance = $client->default_account->load->balance;
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (qw(
            transaction_id
            contract_id
            balance_after
            purchase_time
            buy_price
            start_time
            longcode
            shortcode
            payout
    ));
    is_deeply([sort keys %$result], [sort @expected_keys], 'result keys is ok');
    my $new_balance = $client->default_account->load->balance;
    is($new_balance, $result->{balance_after}, 'balance is changed');
    ok($old_balance - $new_balance - $result->{buy_price} < 0.0001, 'balance reduced');
    like($result->{shortcode}, qr/CALL_R_50_100_\d{10}_\d{10}_S0P_0/, 'shortcode is correct');
    is(
        $result->{longcode},
        '如果随机 50 指数在合约开始时间之后到2 分钟时严格高于入市现价，将获得USD100.00的赔付额。',
        'longcode is correct'
    );


    $contract = BOM::Test::Data::Utility::Product::create_contract(is_spread => 1);
    $params->{contract_parameters} = {
                                      "proposal"      => 1,
                                      "amount"        => "100",
                                      "basis"         => "payout",
                                      "contract_type" => "SPREADU",
                                      "currency"      => "USD",
                                      "stop_profit"   => "10",
                                      "stop_type"     => "point",
                                      "amount_per_point" => "1",
                                      "stop_loss"    => "10",
                                      "symbol"        => "R_50",
                                     };

    $params->{args}{price} = $contract->ask_price;

    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    push @expected_keys, qw(stop_loss_level stop_profit_level amount_per_point);
    is_deeply([sort keys %$result], [sort @expected_keys], 'result spread keys is ok');
    #    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
#            client_loginid => $client->loginid,
#            currency_code  => $client->currency,
#            db             => BOM::Database::ClientDB->new({
#                    client_loginid => $client->loginid,
#                    operation      => 'replica',
#                }
#            )->db,
#        });
#
#    my $fmb = $fmb_dm->get_fmb_by_id([$result->{contract_id}]);
#    ok($fmb->[0], 'have such contract');

};

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

      #reset ticks
      BOM::Test::Data::Utility::FeedTestDatabase->prepare_unit_test_database;

      #sold  contract should be hold 2 minutes and interval should more than 15
      my $contract = BOM::Test::Data::Utility::Product::create_contract(start_time => time - 60 * 2, interval => '20m');
      ok($contract);

      my $buy_params = {};
      $buy_params->{source}              = 1;
      $buy_params->{contract_parameters} = {
                                        "proposal"      => 1,
                                        "amount"        => "100",
                                        "basis"         => "payout",
                                        "contract_type" => "CALL",
                                        "currency"      => "USD",
                                        "duration"      => "120",
                                        "duration_unit" => "s",
                                        "symbol"        => "R_50",
                                       };

      $bug_params->{args}{price} = $contract->ask_price;
      $c->call_ok('buy', $buy_params)->has_no_system_error->has_no_error;
};

done_testing();

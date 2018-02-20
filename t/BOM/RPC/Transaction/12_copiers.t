#!perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Exception;
use Test::Mojo;

use Client::Account;

use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Account;
use BOM::Database::DataMapper::Copier;
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Client::Utility;
use BOM::Platform::Copier;
use BOM::Platform::Password;
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Helper::Client qw( create_client top_up );
use BOM::Test::RPC::Client;

use Test::BOM::RPC::Contract;

Crypt::NamedKeys->keyfile('/etc/rmg/aes_keys.yml');
my $mock_rpc = Test::MockModule->new('BOM::Transaction::Validation');
$mock_rpc->mock(_validate_tnc => sub { note "mocked BOM::Transaction::Validation->validate_tnc returning nothing"; undef });

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});
my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

sub buy_one_bet {
    my ($acc, $args) = @_;

    my $buy_price    = delete $args->{buy_price}    // 20;
    my $payout_price = delete $args->{payout_price} // $buy_price * 10;
    my $limits       = delete $args->{limits};
    my $duration     = delete $args->{duration}     // '15s';

    my $loginid = $acc->client_loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    my $contract = produce_contract(Test::BOM::RPC::Contract::prepare_contract());

    my $params = {
        language            => 'EN',
        token               => $token,
        source              => 1,
        contract_parameters => {
            "proposal"      => 1,
            "amount"        => "100",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "duration"      => "15",
            "duration_unit" => "s",
            "symbol"        => "R_50",
        },
        args => {price => $contract->ask_price}};
    my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
    $mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

    my $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;

    return @{$result}{qw| transaction_id contract_id balance_after buy_price |};
}

sub sell_one_bet {
    my ($acc, $args) = @_;

    my $loginid = $acc->client_loginid;
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
    $mock_validation->mock(_is_valid_to_sell   => sub { note "mocked Transaction::Validation->_is_valid_to_sell returning nothing";   undef });
    $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; undef });
    my $mock_transaction = Test::MockModule->new('BOM::Transaction');
    $mock_transaction->mock(_is_valid_to_sell => sub { note "mocked Transaction::Validation->_is_valid_to_sell returning nothing"; undef });

    my $params = {
        language => 'EN',
        token    => $token,
        source   => 1,
        args     => {sell => $args->{id}}};

    my $result = $c->call_ok('sell', $params)->has_no_system_error->has_no_error->result;

    return @{$result}{qw| balance_after sold_for |};
}

sub set_allow_copiers {
    my $client = shift;

    my $email = 'unit_test@binary.com';
    my $loginid = $client->loginid;
    my $user    = BOM::Platform::User->create(
        email    => $email,
        password => '1234',
    );
    $user->add_loginid({loginid => $loginid});
    $user->save;

    my $res = BOM::RPC::v3::Accounts::set_settings({
        args => {
            set_settings    => 1,
            allow_copiers   => 1,
            
            # This field is unrelated to the test, but required for this call to succeed
            account_opening_reason   => "Speculative",
        },
        client => $client,
        website_name => 'Binary.com',
        client_ip    => '127.0.0.1',
        user_agent   => '12_copiers.t',
        language     => 'en',
    });
    is($res->{status}, 1, "allow_copiers set successfully");
}

####################################################################
# real tests begin here
####################################################################

my $balance;
my ($trader, $trader_acc, $copier, $trader_acc_mapper, $copier_acc_mapper, $txnid, $fmbid, $balance_after, $buy_price);

lives_ok {
    $trader = create_client;
    $copier = create_client;

    set_allow_copiers($trader);

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $trader->loginid);
    my $token_details = BOM::RPC::v3::Utility::get_token_details($token);
    $trader_acc_mapper = BOM::Database::DataMapper::Account->new({
        'client_loginid' => $trader->loginid,
        'currency_code'  => 'USD',
    });

    $balance = 15000;
    top_up $trader, 'USD', $balance;
    top_up $copier, 'USD', 1;

    isnt($trader_acc = $trader->find_account(query => [currency_code => 'USD'])->[0], undef, 'got USD account');

    is(int($trader_acc_mapper->get_balance), 15000, 'USD balance is 15000 got: ' . $balance);

    my $res = BOM::RPC::v3::CopyTrading::copy_start({
        args => {
            copy_start => $token,
        },
        client => $copier
    });

    ok($res && $res->{status}, "start following");
}
'trader funded';

lives_ok {
    my $wrong_copier = create_client;
    top_up $wrong_copier, 'USD', 15000;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $trader->loginid);

    my $res = BOM::RPC::v3::CopyTrading::copy_start({
            args => {
                copy_start  => $token,
                trade_types => 'CAL',
            },
            client => $wrong_copier
        });

    is($res && $res->{error}{code}, 'InvalidTradeType', "following attepmt. InvalidTradeType");
    $res = BOM::RPC::v3::CopyTrading::copy_start({
            args => {
                copy_start  => $token,
                trade_types => 'CALL',
                assets      => 'R666'
            },
            client => $wrong_copier
        });

    ok($res && $res->{error}{code}, "following attepmt. Invalid symbol");

    $res = BOM::RPC::v3::CopyTrading::copy_start({
            args => {
                copy_start => "Invalid",
            },
            client => $wrong_copier
        });

    is($res->{error}{code}, "InvalidToken", "following attepmt. InvalidToken");

    my ($token1) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $wrong_copier->loginid);

    $res = BOM::RPC::v3::CopyTrading::copy_start({
            args => {
                copy_start => $token1,
            },
            client => $trader
        });

    is($res->{error}{code}, 'CopyTradingNotAllowed', "following attepmt. CopyTradingNotAllowed");
}
'following validation';

lives_ok {
    my $wrong_copier = create_client('MF');
    top_up $wrong_copier, 'EUR', 1000;
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $trader->loginid);

    my $res = BOM::RPC::v3::CopyTrading::copy_start({
            args => {
                copy_start  => $token,
                trade_types => 'CALL',
            },
            client => $wrong_copier
        });
    is($res->{error}{code}, 'CopyTradingWrongCurrency', 'check currency');
}
'Wrong currency';

lives_ok {
    ($txnid, $fmbid, $balance_after, $buy_price) = buy_one_bet($trader_acc);

    $balance -= $buy_price;
    is(int $balance_after, int $balance, 'correct balance_after');
}
'bought USD bet';

lives_ok {
    top_up $copier, 'USD', 14999;
    $copier_acc_mapper = BOM::Database::DataMapper::Account->new({
        'client_loginid' => $copier->loginid,
        'currency_code'  => 'USD',
    });

    is(int $copier_acc_mapper->get_balance, 15000, 'USD balance is 15000 got: ' . $balance);
}
'copier funded';

lives_ok {
    ($txnid, $fmbid, $balance_after, $buy_price) = buy_one_bet($trader_acc);

    is(int $copier_acc_mapper->get_balance, int(15000 - $buy_price), 'correct copier balance');
    $balance -= $buy_price;
    is(int $balance_after, int $balance, 'correct balance_after');
}
'bought 2nd USD bet';

sleep 1;

lives_ok {
    my $copier_balance = $copier_acc_mapper->get_balance + 0;
    my $trader_balance = $trader_acc_mapper->get_balance + 0;

    ($balance_after, my $sell_price) = sell_one_bet(
        $trader_acc,
        +{
            id => $fmbid,
        });

    is(int $copier_acc_mapper->get_balance, int($copier_balance + $sell_price), "correct copier balance");

    is(int $trader_acc_mapper->get_balance, int($trader_balance + $sell_price), "correct trader balance");
}
'sell 2nd a bet';

lives_ok {
    my $copiers = BOM::Database::DataMapper::Copier->new(
        broker_code => $trader->broker_code,
        operation   => 'replica',
        )->get_trade_copiers({
            trader_id => $trader->loginid,
        });
    is(scalar @$copiers, 1, 'get_trade_copiers');
    note explain $copiers;
}
'get_trader_copiers';

lives_ok {
    my $loginid = $trader->loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    my $res = BOM::RPC::v3::CopyTrading::copy_stop({
            args => {
                copy_stop => $token,
            },
            client => $copier
        });
    ok($res && $res->{status}, "stop following");
    my $copier_balance = $copier_acc_mapper->get_balance + 0;
    my $trader_balance = $trader_acc_mapper->get_balance + 0;

    ($txnid, $fmbid, $balance_after, $buy_price) = buy_one_bet($trader_acc);
    is(int($copier_acc_mapper->get_balance), int($copier_balance), "correct copier balance");

    is(int($trader_acc_mapper->get_balance), int($trader_balance - $buy_price), "correct trader balance");

}
'unfollowing';

done_testing;

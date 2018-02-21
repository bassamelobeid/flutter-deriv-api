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

my %default_call_params = (
    client_ip    => '127.0.0.1',
    user_agent   => '12_copiers.t',
    language     => 'EN',
);

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

    my $email = $client->email;
    my $loginid = $client->loginid;
    my $user    = BOM::Platform::User->create(
        email    => $email,
        password => '1234',
    );
    $user->add_loginid({loginid => $loginid});
    $user->save;

    my $args = {
        set_settings    => 1,
        allow_copiers   => 1
    };
    if (not $client->is_virtual){
        # This field is unrelated to the test, but required for this call to succeed on a real money account
        $args->{account_opening_reason} = "Speculative";
    }

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    my $res = $c->call_ok('set_settings', {
        args => $args,
        token => $token,
        %default_call_params
    })->result;

    is($res->{status}, 1, "allow_copiers set successfully");
}

sub start_copy_trade {
    my ($trader, $copier) = @_;

    my ($trader_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $trader->loginid);
    my ($copier_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $copier->loginid);

    my $res = $c->call_ok('copy_start', {
        args => {
            copy_start => $trader_token,
        },
        token => $copier_token,
        %default_call_params
    })->has_no_error->result;
    ok($res && $res->{status}, "start following");
}

sub start_copy_trade_with_error_code {
    my $trader      = shift;
    my $copier      = shift;
    my $error_code  = shift;
    my $error_msg   = shift;
    my $extra_args  = shift || {};

    my ($trader_token) = (defined $trader) ? BOM::Database::Model::OAuth->new->store_access_token_only(1, $trader->loginid) : "Invalid";
    my ($copier_token) = (defined $copier) ? BOM::Database::Model::OAuth->new->store_access_token_only(1, $copier->loginid) : "Invalid";

    my $res = $c->call_ok('copy_start', {
        args => {
            copy_start => $trader_token,
            %$extra_args
        },
        token => $copier_token,
        %default_call_params
    })->has_error->error_code_is($error_code, $error_msg);
}

sub stop_copy_trade {
    my ($trader, $copier) = @_;

    my ($trader_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $trader->loginid);
    my ($copier_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $copier->loginid);

    my $res = $c->call_ok('copy_stop', {
        args => {
            copy_stop => $trader_token,
        },
        token => $copier_token,
        %default_call_params
    })->has_no_error->result;
    ok($res && $res->{status}, "stop following");
}

####################################################################
# real tests begin here
####################################################################

my $balance;
my ($trader, $trader_acc, $copier, $trader_acc_mapper, $copier_acc_mapper, $txnid, $fmbid, $balance_after, $buy_price);

subtest 'Setup and fund trader' => sub {
    $trader = create_client;
    $copier = create_client;

    $trader_acc_mapper = BOM::Database::DataMapper::Account->new({
        'client_loginid' => $trader->loginid,
        'currency_code'  => 'USD',
    });

    $balance = 15000;
    top_up $trader, 'USD', $balance;
    top_up $copier, 'USD', 1;

    isnt($trader_acc = $trader->find_account(query => [currency_code => 'USD'])->[0], undef, 'got USD account');

    is(int($trader_acc_mapper->get_balance), 15000, 'USD balance is 15000 got: ' . $balance);

    set_allow_copiers($trader);
    start_copy_trade($trader, $copier);
};

subtest 'Invalid trade type error' => sub {
    my $wrong_copier = create_client;
    top_up $wrong_copier, 'USD', 15000;

    my $extra_args = {
            trade_types => 'CAL',
    };
    start_copy_trade_with_error_code($trader, $wrong_copier, 'InvalidTradeType', 'following attepmt. InvalidTradeType', $extra_args);
};

subtest 'Invalid symbol error' => sub {
    my $wrong_copier = create_client;
    top_up $wrong_copier, 'USD', 15000;

    my $extra_args = {
            trade_types => 'CALL',
            assets      => 'R666'
    };
    start_copy_trade_with_error_code($trader, $wrong_copier, 'InvalidSymbol', 'following attepmt. InvalidSymbol', $extra_args);
};

subtest 'Invalid token error' => sub {
    my $wrong_copier = create_client;
    top_up $wrong_copier, 'USD', 15000;

    start_copy_trade_with_error_code(undef, $wrong_copier, 'InvalidToken', 'following attepmt. InvalidToken');
};

subtest 'Copy trading not allowed error' => sub {
    my $wrong_copier = create_client;
    top_up $wrong_copier, 'USD', 15000;

    start_copy_trade_with_error_code($wrong_copier, $trader, 'CopyTradingNotAllowed', 'following attepmt. CopyTradingNotAllowed');
};

subtest 'Wrong currency error' => sub {
    my $wrong_copier = create_client('MF');
    top_up $wrong_copier, 'EUR', 1000;

    my $extra_args = {
            trade_types => 'CALL',
    };
    start_copy_trade_with_error_code($trader, $wrong_copier, 'CopyTradingWrongCurrency', 'check currency', $extra_args);
};

subtest 'Buy USD bet' => sub {
    ($txnid, $fmbid, $balance_after, $buy_price) = buy_one_bet($trader_acc);

    $balance -= $buy_price;
    is(int $balance_after, int $balance, 'correct balance_after');
};

subtest 'Fund copier' => sub {
    top_up $copier, 'USD', 14999;
    $copier_acc_mapper = BOM::Database::DataMapper::Account->new({
        'client_loginid' => $copier->loginid,
        'currency_code'  => 'USD',
    });

    is(int $copier_acc_mapper->get_balance, 15000, 'USD balance is 15000 got: ' . $balance);
};

subtest 'Buy 2nd USD bet' => sub {
    ($txnid, $fmbid, $balance_after, $buy_price) = buy_one_bet($trader_acc);

    is(int $copier_acc_mapper->get_balance, int(15000 - $buy_price), 'correct copier balance');
    $balance -= $buy_price;
    is(int $balance_after, int $balance, 'correct balance_after');
};

sleep 1;

subtest 'Sell 2nd USD bet' => sub {
    my $copier_balance = $copier_acc_mapper->get_balance + 0;
    my $trader_balance = $trader_acc_mapper->get_balance + 0;

    ($balance_after, my $sell_price) = sell_one_bet(
        $trader_acc,
        +{
            id => $fmbid,
        });

    is(int $copier_acc_mapper->get_balance, int($copier_balance + $sell_price), "correct copier balance");

    is(int $trader_acc_mapper->get_balance, int($trader_balance + $sell_price), "correct trader balance");
};

subtest 'Get trader copiers' => sub {
    my $copiers = BOM::Database::DataMapper::Copier->new(
        broker_code => $trader->broker_code,
        operation   => 'replica',
        )->get_trade_copiers({
            trader_id => $trader->loginid,
        });
    is(scalar @$copiers, 1, 'get_trade_copiers');
    note explain $copiers;
};

subtest 'Unfollow' => sub {
    stop_copy_trade($trader, $copier);

    my $copier_balance = $copier_acc_mapper->get_balance + 0;
    my $trader_balance = $trader_acc_mapper->get_balance + 0;

    ($txnid, $fmbid, $balance_after, $buy_price) = buy_one_bet($trader_acc);
    is(int($copier_acc_mapper->get_balance), int($copier_balance), "correct copier balance");

    is(int($trader_acc_mapper->get_balance), int($trader_balance - $buy_price), "correct trader balance");

};

done_testing;

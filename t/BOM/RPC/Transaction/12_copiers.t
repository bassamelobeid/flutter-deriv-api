#!perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
#use Test::NoWarnings ();    # no END block test
#use Test::Warnings qw(warnings);
use Test::Exception;

use Client::Account;

use BOM::Database::ClientDB;
use BOM::Platform::Password;
use BOM::Platform::Client::Utility;

use BOM::Platform::Copier;
use BOM::Database::DataMapper::Copier;
use BOM::Database::DataMapper::Account;
use Test::Mojo;
use BOM::Test::RPC::Client;
use Test::BOM::RPC::Contract;
use BOM::Platform::Client::IDAuthentication;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

Crypt::NamedKeys->keyfile('/etc/rmg/aes_keys.yml');
my $mock_rpc = Test::MockModule->new('BOM::RPC');
$mock_rpc->mock(_validate_tnc => sub { note "mocked RPC->validate_tnc returning nothing"; undef });

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

sub create_client {
    return Client::Account->register_and_return_new_client({
        broker_code      => 'CR',
        client_password  => BOM::Platform::Password::hashpw('12345678'),
        salutation       => 'Mr',
        last_name        => 'Doe',
        first_name       => 'John' . time . '.' . int(rand 1000000000),
        email            => 'john.doe' . time . '.' . int(rand 1000000000) . '@test.domain.nowhere',
        residence        => 'in',
        address_line_1   => '298b md rd',
        address_line_2   => '',
        address_city     => 'Place',
        address_postcode => '65432',
        address_state    => 'st',
        phone            => '+9145257468',
        secret_question  => 'What the f***?',
        secret_answer    => BOM::Platform::Client::Utility::encrypt_secret_answer('is that'),
        date_of_birth    => '1945-08-06',
    });
}

sub top_up {
    my ($c, $cur, $amount) = @_;

    my $fdp = $c->is_first_deposit_pending;
    my @acc = $c->account;

    return if (@acc && $acc[0]->currency_code ne $cur);

    if (not @acc) {
        @acc = $c->add_account({
            currency_code => $cur,
            is_default    => 1
        });
    }

    my $acc = $acc[0];
    unless (defined $acc->id) {
        $acc->save;
        note 'Created account ' . $acc->id . ' for ' . $c->loginid . ' segment ' . $cur;
    }

    my ($pm) = $acc->add_payment({
        amount               => $amount,
        payment_gateway_code => "legacy_payment",
        payment_type_code    => "ewallet",
        status               => "OK",
        staff_loginid        => "test",
        remark               => __FILE__ . ':' . __LINE__,
    });
    $pm->legacy_payment({legacy_type => "ewallet"});
    my ($trx) = $pm->add_transaction({
        account_id    => $acc->id,
        amount        => $amount,
        staff_loginid => "test",
        remark        => __FILE__ . ':' . __LINE__,
        referrer_type => "payment",
        action_type   => ($amount > 0 ? "deposit" : "withdrawal"),
        quantity      => 1,
    });
    $acc->save(cascade => 1);
    $trx->load;    # to re-read (get balance_after)

    BOM::Platform::Client::IDAuthentication->new(client => $c)->run_authentication
        if $fdp;

    note $c->loginid . "'s balance is now $cur " . $trx->balance_after . "\n";
}

sub buy_one_bet {
    my ($acc, $args) = @_;

    my $buy_price    = delete $args->{buy_price}    // 20;
    my $payout_price = delete $args->{payout_price} // $buy_price * 10;
    my $limits       = delete $args->{limits};
    my $duration     = delete $args->{duration}     // '15s';

    my $loginid = $acc->client_loginid;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    my $contract = Test::BOM::RPC::Contract::create_contract();

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
    $mock_validation->mock(_is_valid_to_sell => sub { note "mocked Transaction::Validation->_is_valid_to_sell returning nothing"; undef });
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

####################################################################
# real tests begin here
####################################################################

my $balance;
my ($trader, $trader_acc, $copier, $trader_acc_mapper, $copier_acc_mapper, $txnid, $fmbid, $balance_after, $buy_price);

lives_ok {
    $trader = create_client;
    $copier = create_client;

    $trader->allow_copiers(1);
    $trader->save;

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $trader->loginid);
    my $token_details = BOM::RPC::v3::Utility::get_token_details($token);

    my $res = BOM::RPC::v3::CopyTrading::copy_start({
            args => {
                copy_start => $token,
            },
            client => $copier
        });

    #is($res && $res->{error}{code},'PermissionDenied', "start following attepmt. PermissionDenied");
    ok($res && $res->{status}, "start following");
    $trader_acc_mapper = BOM::Database::DataMapper::Account->new({
        'client_loginid' => $trader->loginid,
        'currency_code'  => 'USD',
    });

    $balance = 15000;
    top_up $trader, 'USD', $balance;

    isnt($trader_acc = $trader->find_account(query => [currency_code => 'USD'])->[0], undef, 'got USD account');

    is($trader_acc_mapper->get_balance + 0, 15000, 'USD balance is 15000 got: ' . $balance);
}
'trader funded';

lives_ok {
    my $wrong_copier = create_client;
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
    ($txnid, $fmbid, $balance_after, $buy_price) = buy_one_bet($trader_acc);
    $balance -= $buy_price;
    is($balance_after + 0, $balance, 'correct balance_after');
}
'bought USD bet';

lives_ok {
    top_up $copier, 'USD', 15000;

    $copier_acc_mapper = BOM::Database::DataMapper::Account->new({
        'client_loginid' => $copier->loginid,
        'currency_code'  => 'USD',
    });

    is($copier_acc_mapper->get_balance + 0, 15000, 'USD balance is 15000 got: ' . $balance);
}
'copier funded';

lives_ok {
    ($txnid, $fmbid, $balance_after, $buy_price) = buy_one_bet($trader_acc);
    is($copier_acc_mapper->get_balance + 0, 15000 - $buy_price, 'correct copier balance');
    $balance -= $buy_price;
    is($balance_after + 0, $balance, 'correct balance_after');
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

    is($copier_acc_mapper->get_balance, $copier_balance + $sell_price, "correct copier balance");

    is($trader_acc_mapper->get_balance, $trader_balance + $sell_price, "correct trader balance");
}
'sell 2nd a bet';

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
    is($copier_acc_mapper->get_balance, $copier_balance, "correct copier balance");

    is($trader_acc_mapper->get_balance, $trader_balance - $buy_price, "correct trader balance");

}
'unfollowing';

done_testing;

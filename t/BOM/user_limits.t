#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 8;
use Test::Exception;
use Guard;
use Crypt::NamedKeys;
use BOM::User::Client;
use BOM::User::Password;
use BOM::User::Utility;

use Date::Utility;
use BOM::Transaction;
use BOM::Transaction::Validation;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(top_up);
use BOM::Platform::Client::IDAuthentication;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::User;
use BOM::User::Password;

use BOM::Database::ClientDB;
use BOM::Database::Helper::UserSpecificLimit;

my $mocked_CurrencyConverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
$mocked_CurrencyConverter->mock(
    'in_usd',
    sub {
        my $price         = shift;
        my $from_currency = shift;

        $from_currency eq 'AUD' and return 0.90 * $price;
        $from_currency eq 'BCH' and return 1200 * $price;
        $from_currency eq 'ETH' and return 500 * $price;
        $from_currency eq 'LTC' and return 120 * $price;
        $from_currency eq 'EUR' and return 1.18 * $price;
        $from_currency eq 'GBP' and return 1.3333 * $price;
        $from_currency eq 'JPY' and return 0.0089 * $price;
        $from_currency eq 'BTC' and return 5500 * $price;
        $from_currency eq 'USD' and return 1 * $price;
        return 0;
    });

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

my $now = Date::Utility->new->minus_time_interval('1s');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(JPY USD JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => $now
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });

my $usdjpy = 'frxUSDJPY';
my $r50    = 'R_50';

my ($r50_tick, $usdjpy_tick) =
    map { BOM::Test::Data::Utility::FeedTestDatabase::create_tick({epoch => $now->epoch, underlying => $_,}) } ($r50, $usdjpy);

# Spread is calculated base on spot of the underlying.
# In this case, we mocked the spot to 100.
my $mocked_underlying = Test::MockModule->new('Quant::Framework::Underlying');
$mocked_underlying->mock('spot', sub { 100 });

my $underlying = create_underlying('R_50');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub create_client {
    return $user->create_client(
        broker_code      => 'CR',
        client_password  => BOM::User::Password::hashpw('12345678'),
        salutation       => 'Ms',
        last_name        => 'Doe',
        first_name       => 'Jane' . time . '.' . int(rand 1000000000),
        email            => 'jane.doe' . time . '.' . int(rand 1000000000) . '@test.domain.nowhere',
        residence        => 'in',
        address_line_1   => '298b md rd',
        address_line_2   => '',
        address_city     => 'Place',
        address_postcode => '65432',
        address_state    => 'st',
        phone            => '+9145257468',
        secret_question  => 'What the f***?',
        secret_answer    => BOM::User::Utility::encrypt_secret_answer('is that'),
        date_of_birth    => '1945-08-06',
    );
}

my $cl;
my $acc_usd;
my $acc_aud;

####################################################################
# real tests begin here
####################################################################

lives_ok {
    $cl = create_client;

    #make sure client can trade
    ok(!BOM::Transaction::Validation->new({clients => [$cl]})->check_trade_status($cl),      "client can trade: check_trade_status");
    ok(!BOM::Transaction::Validation->new({clients => [$cl]})->_validate_client_status($cl), "client can trade: _validate_client_status");

    top_up $cl, 'USD', 5000;

    isnt + ($acc_usd = $cl->account), 'USD', 'got USD account';

    my $bal;
    is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;
}
'client created and funded';

my ($trx, $fmb, $chld, $qv1, $qv2);

my $new_client = create_client;
top_up $new_client, 'USD', 5000;
my $new_acc_usd = $new_client->account;

my $db = BOM::Database::ClientDB->new({broker_code => 'CR'})->db;

BOM::Config::Runtime->instance->app_config->quants->enable_user_potential_loss(1);
BOM::Config::Runtime->instance->app_config->quants->enable_user_realized_loss(1);

subtest 'potential loss', sub {
    BOM::Database::Helper::UserSpecificLimit->new({
            db             => $db,
            client_loginid => $cl->loginid,
            potential_loss => 50,
            realized_loss  => 50,
            client_type    => 'old',
            market_type    => 'non_financial'
        })->record_user_specific_limit;

    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

    my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
    $mock_validation->mock(
        _validate_trade_pricing_adjustment => sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () }
    );
    $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

    my $mock_transaction = Test::MockModule->new('BOM::Transaction');
    $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

    subtest 'non_financial' => sub {
        my $contract = produce_contract({
            underlying   => $r50,
            date_start   => $now,
            date_pricing => $now,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '15m',
            current_tick => $r50_tick,
            barrier      => 'S0P',
        });

        my $error = do {
            my $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                source        => 19,
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        ok !$error, 'no error if limit matches potential loss';

        $error = do {
            my $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                source        => 19,
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        ok $error, 'error is thrown';
        is $error->{'-mesg'},              'per user potential loss limit reached';
        is $error->{'-message_to_client'}, 'This contract is currently unavailable due to market conditions';
    };

    subtest 'financial' => sub {
        my $contract = produce_contract({
            underlying   => $usdjpy,
            date_start   => $now,
            date_pricing => $now,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '15m',
            current_tick => $usdjpy_tick,
            barrier      => 'S0P',
        });

        my $error = do {
            my $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                source        => 19,
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        ok !$error, 'no error if limit matches potential loss';

        $error = do {
            my $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                source        => 19,
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        ok !$error, 'no error is thrown because no limit is set';
        BOM::Database::Helper::UserSpecificLimit->new({
                db             => $db,
                client_loginid => $cl->loginid,
                potential_loss => 149,
                realized_loss  => 50,
                client_type    => 'old',
                market_type    => 'financial'
            })->record_user_specific_limit;

        $error = do {
            my $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                source        => 19,
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        ok $error, 'error is thrown';
        is $error->{'-mesg'},              'per user potential loss limit reached';
        is $error->{'-message_to_client'}, 'This contract is currently unavailable due to market conditions';
    };
};

subtest 'realized loss' => sub {
    close_all_open_contracts('CR', 1);    # close open contracts with full payout.
    note("current realized financial loss: 100, non_financial realized loss: 50");
    BOM::Database::Helper::UserSpecificLimit->new({
            db             => $db,
            client_loginid => $cl->loginid,
            realized_loss  => $_->[1],
            client_type    => 'old',
            market_type    => $_->[0]}
        )->record_user_specific_limit
        foreach (['financial', 100], ['non_financial', 50]);

    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

    my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
    $mock_validation->mock(
        _validate_trade_pricing_adjustment => sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () }
    );
    $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

    my $mock_transaction = Test::MockModule->new('BOM::Transaction');
    $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

    subtest 'non_financial' => sub {
        my $contract = produce_contract({
            date_start   => $now,
            date_pricing => $now,
            underlying   => $r50,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '15m',
            current_tick => $r50_tick,
            barrier      => 'S0P',
        });

        my $error = do {
            my $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                source        => 19,
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        ok !$error, 'no error if limit matches realized loss';
        sleep(1);
        close_all_open_contracts('CR', 1);    # close open contracts with full payout.
        $error = do {
            my $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                source        => 19,
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        ok $error, 'error is thrown';
        is $error->{'-mesg'},              'per user realized loss limit reached';
        is $error->{'-message_to_client'}, 'This contract is currently unavailable due to market conditions';
    };

    subtest 'financial' => sub {
        my $contract = produce_contract({
            date_start   => $now,
            date_pricing => $now,
            underlying   => $usdjpy,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '15m',
            current_tick => $usdjpy_tick,
            barrier      => 'S0P',
        });

        my $error = do {
            my $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                source        => 19,
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        ok !$error, 'no error if limit matches realized loss';
        sleep(1);
        close_all_open_contracts('CR', 1);    # close open contracts with full payout.
        $error = do {
            my $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                source        => 19,
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        ok $error, 'error is thrown';
        is $error->{'-mesg'},              'per user realized loss limit reached';
        is $error->{'-message_to_client'}, 'This contract is currently unavailable due to market conditions';
    };
};

sub close_all_open_contracts {
    my $broker_code = shift;
    my $fullpayout  = shift // 0;
    my $clientdb    = BOM::Database::ClientDB->new({broker_code => $broker_code});

    my $dbh = $clientdb->db->dbh;
    my $sql = q{select client_loginid,currency_code from transaction.account};
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my $output = $sth->fetchall_arrayref();

    foreach my $client_data (@$output) {
        foreach my $fmbo (
            @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client_data->[0], $client_data->[1], 'false']) // []})
        {
            my $contract = produce_contract($fmbo->{short_code}, $client_data->[1]);
            my $txn = BOM::Transaction->new({
                client   => BOM::User::Client->new({loginid => $client_data->[0]}),
                contract => $contract,
                source   => 23,
                price => ($fullpayout ? $fmbo->{payout_price} : $fmbo->{buy_price}),
                contract_id   => $fmbo->{id},
                purchase_date => $contract->date_start,
            });
            $txn->sell(skip_validation => 1);
        }
    }
    return;
}

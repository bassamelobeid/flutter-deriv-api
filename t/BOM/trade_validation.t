#!perl

use strict;
use warnings;

use Test::Most tests => 8;
use File::Spec;
use YAML::XS qw(LoadFile);
use Test::Warnings;

use Date::Utility;
use Test::MockObject::Extends;
use Format::Util::Numbers qw(roundcommon);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::User::Client;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
use Math::Util::CalculatedValue::Validatable;
use BOM::Config;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Test::MockTime qw(set_absolute_time);
use Test::MockModule;

initialize_realtime_ticks_db();

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(compliance_checks     => sub { note "mocked Transaction::Validation->compliance_checks returning nothing";     undef });
$mock_validation->mock(check_tax_information => sub { note "mocked Transaction::Validation->check_tax_information returning nothing"; undef });

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for (qw/USD JPY GBP JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol        => 'R_50',
        recorded_date => Date::Utility->new
    });

my $now         = Date::Utility->new;
my $random_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

my $client     = BOM::User::Client->new({loginid => 'MX1001'});
my $currency   = 'GBP';
my $account    = $client->default_account;
my $loginid    = $client->loginid;
my $underlying = create_underlying('frxUSDJPY');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new($now->epoch - 100),
    }) for qw/frxUSDJPY frxGBPJPY frxGBPUSD/;

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

populate_exchange_rates();

my $contract = produce_contract({
    underlying  => $underlying,
    bet_type    => 'CALL',
    currency    => $currency,
    payout      => 1000,
    date_start  => $now,
    date_expiry => $now->epoch + 300,
    barrier     => 'S0P',
});

my $mock_call = Test::MockModule->new('BOM::Product::Contract::Call');
subtest 'IOM withdrawal limit' => sub {
    my $withdraw_limit = BOM::Config::payment_limits()->{withdrawal_limits}->{iom}->{limit_for_days};

    $client->payment_free_gift(
        currency     => 'GBP',
        amount       => $withdraw_limit + 2000,
        remark       => 'here is money',
        payment_type => 'free_gift'
    );

    $client->payment_free_gift(
        currency     => 'GBP',
        amount       => -1 * ($withdraw_limit / 2),
        remark       => 'here is money',
        payment_type => 'free_gift'
    );

    my $error;
    lives_ok {
        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });
        $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_iom_withdrawal_limit($client);
    }
    'validate withdrawal limit';
    is($error, undef, 'pass withdrawal limit check');

    $client->payment_free_gift(
        currency     => 'GBP',
        amount       => -1 * ($withdraw_limit / 2 + 1000),
        remark       => 'here is money',
        payment_type => 'free_gift'
    );

    lives_ok {
        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });
        $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_iom_withdrawal_limit($client);
    }
    'validate withdrawal limit';

    is($error->get_type, 'iomWithdrawalLimit', 'unauthenticated IOM client - withdrawal has exceeded limit');
    like(
        $error->{-message_to_client},
        qr/Due to regulatory requirements, you are required to authenticate your account in order to continue trading/,
        'iom client exceeded withdrawal limit msg'
    );
};

subtest 'Is contract valid to buy' => sub {
    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock('is_valid_to_buy', sub { 1 });

    $now = Date::Utility->new;
    my $contract1 = produce_contract({
        underlying  => $underlying,
        bet_type    => 'CALL',
        currency    => $currency,
        payout      => 1000,
        date_start  => $now,
        date_expiry => $now->epoch + 500,
        barrier     => 'S0P',
    });

    my $transaction = BOM::Transaction->new({
        client        => $client,
        contract      => $contract1,
        purchase_date => Date::Utility->new(),
    });

    is(
        BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]}
            )->_is_valid_to_buy($client),
        undef,
        'Contract is valid to buy'
    );

    $mock_contract->unmock_all;

    $contract1->_add_error({
        severity          => 1,
        message           => 'Adding error message',
        message_to_client => 'Error message to be sent to client',
    });

    my $error = BOM::Transaction::Validation->new({
            transaction => $transaction,
            clients     => [$client]})->_is_valid_to_buy($client);
    is($error->get_type, 'InvalidtoBuy', 'Contract is invalid to buy as it contains errors: _is_valid_to_buy - error type');
    my $db = BOM::Database::ClientDB->new({broker_code => $client->broker_code})->db;
    my @output = $db->dbh->selectrow_array("select * from data_collection.rejected_trades where action_type = ?", undef, 'buy');
    is $output[1], 'MX1001', 'client id stored';
    is $output[6], 'Error message to be sent to client', 'correct reason';
};

subtest 'Is contract valid to sell' => sub {
    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock('is_valid_to_sell', sub { 1 });

    $now = Date::Utility->new;

    my $contract1 = produce_contract({
        underlying  => $underlying,
        bet_type    => 'CALL',
        currency    => $currency,
        payout      => 1000,
        date_start  => $now,
        date_expiry => $now->epoch + 300,
        barrier     => 'S0P',
    });

    my $transaction = BOM::Transaction->new({
        client        => $client,
        contract      => $contract1,
        purchase_date => Date::Utility->new(),
    });

    is(
        BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]}
            )->_is_valid_to_sell($client),
        undef,
        'Contract is valid to sell'
    );

    $mock_contract->unmock_all;
    $mock_contract->mock('_validate_trading_times',         sub { undef });
    $mock_contract->mock('_validate_start_and_expiry_date', sub { undef });

    $contract1 = make_similar_contract($contract1, {date_expiry => $now->epoch + 10});
    $transaction = BOM::Transaction->new({
        client        => $client,
        contract      => $contract1,
        purchase_date => Date::Utility->new(),
    });

    my $error = BOM::Transaction::Validation->new({
            transaction => $transaction,
            clients     => [$client]})->_is_valid_to_sell($client);
    is($error->get_type, 'InvalidtoSell', 'Contract is invalid to sell as expiry is too low: _is_valid_to_sell - error type');

    my $db = BOM::Database::ClientDB->new({broker_code => $client->broker_code})->db;
    my @output = $db->dbh->selectrow_array("select * from data_collection.rejected_trades where action_type = ?", undef, 'sell');
    is $output[1], 'MX1001', 'client id stored';
    is $output[6], 'Waiting for entry tick.', 'correct reason';
};

subtest 'contract date pricing Validation' => sub {
    my $now = Date::Utility->new;

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => Date::Utility->new($now->epoch + 300),
        }) for (qw/USD JPY GBP JPY-USD/);

    my $contract = produce_contract({
        underlying   => create_underlying('frxUSDJPY'),
        barrier      => 'S0P',
        bet_type     => 'CALL',
        currency     => 'GBP',
        payout       => 100,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        date_pricing => Date::Utility->new($now->epoch - 100),
    });

    my $error;
    lives_ok {
        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });
        $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_date_pricing($client);
    }
    'validate date pricing';

    is($error->get_type, 'InvalidDatePricing', 'Invalid Date Pricing, time has passed > 20 sec from date_pricing');
    like($error->{-message_to_client}, qr/This contract cannot be properly validated at this time/, 'Invalid Date Pricing msg to client');
};

subtest 'valid currency test' => sub {
    my $mock_contract = Test::MockModule->new('BOM::User::Client');

    subtest 'invalid currency' => sub {
        $mock_contract->mock('currency', sub { 'ABC' });

        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'currency',
            {
                symbol        => $_,
                recorded_date => Date::Utility->new($now->epoch - 100),
            }) for (qw/USD JPY GBP JPY-USD/);

        my $contract = produce_contract({
            underlying   => create_underlying('frxUSDJPY'),
            bet_type     => 'CALL',
            currency     => 'EUR',                                   # this can be mocked later on to invalid currency
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            barrier      => 'S0P',
        });

        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });

        my $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_currency($client);

        my $curr = $contract->currency;
        is($error->get_type, 'InvalidCurrency', 'Invalid currency: _validate_currency - error type');
        like($error->{-message_to_client}, qr/The provided currency $curr is invalid./, 'Invalid currency: _validate_currency - error message');
        $mock_contract->unmock('currency');
    };

    subtest 'not default currency for client' => sub {
        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'currency',
            {
                symbol        => $_,
                recorded_date => Date::Utility->new($now->epoch - 100),
            }) for (qw/USD JPY GBP JPY-USD/);

        my $contract = produce_contract({
            underlying   => create_underlying('frxUSDJPY'),
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            barrier      => 'S0P',
        });

        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });

        my $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_currency($client);

        my $curr   = $contract->currency;
        my $broker = $client->broker;

        is($error->get_type, 'NotDefaultCurrency', 'wrong default currency');
        like($error->{-message_to_client}, qr/The provided currency USD is not the default currency/, 'wrong default currency - error message');
    };
};

subtest 'Purchase Sell Contract' => sub {
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MLT'});
    my $currency = 'USD';
    $client->set_default_account($currency);

    $client->payment_free_gift(
        amount   => 2000,
        remark   => 'free money',
        currency => $currency
    );

    $now = Date::Utility->new;
    my $expiry = $now->plus_time_interval('1d');
    $expiry = $expiry->truncate_to_day->plus_time_interval('23h59m59s');

    my $bet_type = 'CALL';
    $contract = produce_contract({
        underlying   => 'R_50',
        bet_type     => $bet_type,
        currency     => $currency,
        payout       => 100,
        date_start   => Date::Utility->new($now->epoch),
        date_pricing => $now->epoch,
        date_expiry  => $expiry,
        entry_tick   => $random_tick,
        current_tick => $random_tick,
        barrier      => 'S0P',
    });

    my $bpt = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        amount_type   => 'payout',
        purchase_date => $contract->date_start,
    });

    my $error = $bpt->buy;
    like($error, qr/ASK_TNC_APPROVAL/, 'TNC validation failed');

    my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

    $mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

    $error = $bpt->buy;
    like($error, qr/PleaseAuthenticate/, 'Account authentication validation failed');
    $mock_validation->mock(check_trade_status => sub { note "mocked Transaction::Validation->check_trade_status returning nothing"; undef });

    $error = $bpt->buy;
    is($error, undef, 'Able to purchase the contract successfully');

    my $trx = $bpt->transaction_record;
    my $fmb = $trx->financial_market_bet;

    ok($trx->account_id, 'can retrieve the trx db record');
    ok($fmb->account_id, 'can retrieve the fmb db record');

    set_absolute_time($now->epoch + 61);
    my $exit_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch + 1,
        underlying => 'R_50',
    });
    my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch + 60,
        underlying => 'R_50',
    });
    $contract = produce_contract({
        underlying  => 'R_50',
        bet_type    => $bet_type,
        currency    => $currency,
        payout      => 100,
        date_start  => $now,
        date_expiry => $expiry,
        # Opposite contract can now be used to purchase. To simulate sellback behaviour,
        # set date_pricing to date_start + 1
        date_pricing => $now->epoch + 1,
        entry_tick   => $random_tick,
        current_tick => $current_tick,
        exit_tick    => $exit_tick,
        barrier      => 'S0P',
    });
    my $mocked = Test::MockModule->new('BOM::Transaction::Validation');
    $mocked->mock('_validate_sell_pricing_adjustment', sub { });
    $error = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $client,
            contract      => $contract,
            price         => $contract->bid_price,
            contract_id   => $bpt->contract_id,
            amount_type   => 'payout'
        })->sell;

    is($error, undef, 'Able to sell the contract successfully');
};

subtest 'validate stake limit' => sub {
    my $contract = produce_contract({
        underlying   => create_underlying('frxUSDJPY'),
        bet_type     => 'CALL',
        currency     => 'GBP',
        payout       => 100,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        date_pricing => Date::Utility->new($now->epoch - 100),
        current_tick => $tick,
        barrier      => 'S0P',
    });
    Test::MockObject::Extends->new($contract);
    $contract->mock('ask_price', sub { 0.5 });
    my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            action        => 'BUY',
            price         => 0.5,
            payout        => 100,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,

    });
    ok !BOM::Transaction::Validation->new({
            transaction => $transaction,
            clients     => [$client]})->_validate_stake_limit($client), 'can buy with minimum stake of 0.5 for non MF broker';
    $contract->mock('ask_price', sub { 0.49 });
    lives_ok {
        my $err = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_stake_limit($client);
        like($err->{-message_to_client}, qr/This contract's price is/, 'correct error message');
    }
    'error out on 0.49 stake for non MF borker';
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
    $contract = produce_contract({
        underlying      => create_underlying('frxUSDJPY'),
        bet_type        => 'CALL',
        currency        => 'GBP',
        payout          => 100,
        date_start      => $now,
        date_expiry     => $now->epoch + 300,
        date_pricing    => Date::Utility->new($now->epoch - 100),
        current_tick    => $tick,
        barrier         => 'S0P',
        landing_company => 'maltainvest',
    });
    Test::MockObject::Extends->new($contract);
    $contract->mock('ask_price', sub { 5 });
    $transaction = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        action        => 'BUY',
        price         => 5,
        payout        => 100,
        amount_type   => 'stake',
        purchase_date => $contract->date_start,
    });
    ok !BOM::Transaction::Validation->new({
            transaction => $transaction,
            clients     => [$client]})->_validate_stake_limit($client), 'can buy with minimum stake of 5 for MF broker';
    $contract->mock('ask_price', sub { 4.9 });
    lives_ok {
        my $err = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_stake_limit($client);
        like($err->{-message_to_client}, qr/This contract's price is/, 'correct error message');
    }
    'error out on 4.9 stake for MF borker';
};

done_testing();

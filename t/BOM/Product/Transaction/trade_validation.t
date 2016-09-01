use strict;
use warnings;

use Test::Most tests => 10;
use Test::NoWarnings;
use File::Spec;
use JSON qw(decode_json);

use Test::MockObject::Extends;
use Format::Util::Numbers qw(roundnear);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Platform::Client;
use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Math::Util::CalculatedValue::Validatable;

use Test::MockTime qw(set_absolute_time);
use Test::MockModule;

initialize_realtime_ticks_db();

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events',
    {
        events           => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]
    });

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

my $client     = BOM::Platform::Client->new({loginid => 'MX1001'});
my $currency   = 'GBP';
my $account    = $client->default_account;
my $loginid    = $client->loginid;
my $underlying = BOM::Market::Underlying->new('frxUSDJPY');

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

$underlying->set_combined_realtime({
    epoch => $now->epoch,
    quote => '97.14'
});

my $contract = produce_contract({
    underlying  => $underlying,
    bet_type    => 'FLASHU',
    currency    => $currency,
    payout      => 1000,
    date_start  => $now,
    date_expiry => $now->epoch + 300,
    barrier     => 'S0P',
});

subtest 'IOM withdrawal limit' => sub {
    plan tests => 5;

    my $withdraw_limit = BOM::Platform::Runtime->instance->app_config->payments->withdrawal_limits->iom->limit_for_days;

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
        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
        });
        $error = $transaction->_validate_iom_withdrawal_limit;
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
        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
        });
        $error = $transaction->_validate_iom_withdrawal_limit;
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
    plan tests => 2;

    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock('is_valid_to_buy', sub { 1 });

    $now = Date::Utility->new;
    my $contract1 = produce_contract({
        underlying  => $underlying,
        bet_type    => 'FLASHU',
        currency    => $currency,
        payout      => 1000,
        date_start  => $now,
        date_expiry => $now->epoch + 500,
        barrier     => 'S0P',
    });

    my $transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract1,
    });

    is($transaction->_is_valid_to_buy, undef, 'Contract is valid to buy');

    $mock_contract->unmock_all;

    $contract1->add_error({
        severity          => 1,
        message           => 'Adding error message',
        message_to_client => 'Error message to be sent to client',
    });

    my $error = $transaction->_is_valid_to_buy;
    is($error->get_type, 'InvalidtoBuy', 'Contract is invalid to buy as it contains errors: _is_valid_to_buy - error type');

};

subtest 'Is contract valid to sell' => sub {
    plan tests => 2;

    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock('is_valid_to_sell', sub { 1 });

    $now = Date::Utility->new;

    my $contract1 = produce_contract({
        underlying  => $underlying,
        bet_type    => 'FLASHU',
        currency    => $currency,
        payout      => 1000,
        date_start  => $now,
        date_expiry => $now->epoch + 300,
        barrier     => 'S0P',
    });

    my $transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract1,
    });

    is($transaction->_is_valid_to_sell, undef, 'Contract is valid to sell');

    $mock_contract->unmock_all;
    $mock_contract->mock('_validate_trading_times', sub { undef });
    $mock_contract->mock('_validate_start_and_expiry_date', sub { undef });

    $contract1 = make_similar_contract($contract1, {date_expiry => $now->epoch + 10});
    $transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract1,
    });

    my $error = $transaction->_is_valid_to_sell;
    is($error->get_type, 'InvalidtoSell', 'Contract is invalid to sell as expiry is too low: _is_valid_to_sell - error type');

};

subtest 'contract date pricing Validation' => sub {
    plan tests => 3;

    my $now = Date::Utility->new;

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => Date::Utility->new($now->epoch + 300),
        }) for (qw/USD JPY GBP JPY-USD/);

    my $contract = produce_contract({
        underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
        bet_type     => 'FLASHU',
        currency     => 'GBP',
        payout       => 100,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        date_pricing => Date::Utility->new($now->epoch - 100),
    });

    my $error;
    lives_ok {
        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
        });
        $error = $transaction->_validate_date_pricing;
    }
    'validate date pricing';

    is($error->get_type, 'InvalidDatePricing', 'Invalid Date Pricing, time has passed > 20 sec from date_pricing');
    like($error->{-message_to_client}, qr/This contract cannot be properly validated at this time/, 'Invalid Date Pricing msg to client');
};

subtest 'valid currency test' => sub {
    plan tests => 3;

    my $mock_contract = Test::MockModule->new('BOM::Platform::Client');

    subtest 'invalid currency' => sub {
        $mock_contract->mock('currency', sub { 'ABC' });

        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'currency',
            {
                symbol        => $_,
                recorded_date => Date::Utility->new($now->epoch - 100),
            }) for (qw/USD JPY GBP JPY-USD/);

        my $contract = produce_contract({
            underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
            bet_type     => 'FLASHU',
            currency     => 'ABC',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
        });

        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
        });

        my $error = $transaction->_validate_available_currency;

        my $curr = $contract->currency;
        is($error->get_type, 'InvalidCurrency', 'Invalid currency: _validate_currency - error type');
        like($error->{-message_to_client}, qr/The provided currency $curr is invalid./, 'Invalid currency: _validate_currency - error message');
    };

    subtest 'illegal currency for landing company' => sub {
        $mock_contract->mock('currency', sub { 'AUD' });

        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'currency',
            {
                symbol        => $_,
                recorded_date => Date::Utility->new($now->epoch - 100),
            }) for (qw/USD JPY GBP JPY-USD/);

        my $contract = produce_contract({
            underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
            bet_type     => 'FLASHU',
            currency     => 'AUD',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
        });

        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
        });

        my $error = $transaction->_validate_currency;

        my $curr   = $contract->currency;
        my $broker = $client->broker;
        is($error->get_type, 'IllegalCurrency', 'Illegal currency: _validate_currency - error type');
        like(
            $error->{-message_to_client},
            qr/$curr transactions may not be performed with this account./,
            'Invalid currency: _validate_currency - error message'
        );

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
            underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
            bet_type     => 'FLASHU',
            currency     => 'AUD',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
        });

        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
        });

        my $error = $transaction->_validate_currency;

        my $curr   = $contract->currency;
        my $broker = $client->broker;
        is($error->get_type, 'NotDefaultCurrency', 'wrong default currency');
        like($error->{-message_to_client}, qr/The provided currency AUD is not the default currency/, 'wrong default currency - error message');
    };
};

subtest 'BUY - trade pricing adjustment' => sub {
    plan tests => 3;

    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');

    subtest 'do not allow move if recomputed is 1' => sub {
        $mock_contract->mock('ask_price', sub { 100 });
        $mock_contract->mock(
            'commission_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'commission_markup',
                    description => 'fake commission markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0.01,
                });
            });
        $mock_contract->mock(
            'risk_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'risk_markup',
                    description => 'fake risk markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0,
                });
            });
        my $ask_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'ask_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 1
        });
        $mock_contract->mock('ask_probability', sub { $ask_cv });
        my $allowed_move = 0.01 * 0.50;

        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'currency',
            {
                symbol        => $_,
                recorded_date => Date::Utility->new($now->epoch - 100),
            }) for (qw/USD JPY GBP JPY-USD/);

        my $contract = produce_contract({
            underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
            bet_type     => 'FLASHU',
            currency     => 'GBP',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $price = $contract->ask_price - ($allowed_move * $contract->payout) + 0.1;
        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            action   => 'BUY',
            price    => $price,
        });
        my $error = $transaction->_validate_trade_pricing_adjustment;
        is($error, undef, 'no error');
        cmp_ok($transaction->price, '==', 100, 'BUY at the recomputed price');
    };

    subtest 'check price move' => sub {
        $mock_contract->mock('ask_price', sub { 10 });
        $mock_contract->mock(
            'commission_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'commission_markup',
                    description => 'fake commission markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0.01,
                });
            });
        $mock_contract->mock(
            'risk_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'risk_markup',
                    description => 'fake risk markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0,
                });
            });
        my $ask_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'ask_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 0.1
        });
        $mock_contract->mock('ask_probability', sub { $ask_cv });

        my $allowed_move = 0.01 * 0.50;

        my $contract = produce_contract({
            underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
            bet_type     => 'FLASHU',
            currency     => 'GBP',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            current_tick => $tick,
            barrier      => 'S0P',
        });

        # amount_type = payout, price increase > allowed move
        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            action   => 'BUY',
            price    => $contract->ask_price - ($allowed_move * $contract->payout + 0.1),
        });
        my $error = $transaction->_validate_trade_pricing_adjustment;
        is($error->get_type, 'PriceMoved', 'Price move too much opposite favour of client');
        like(
            $error->{-message_to_client},
            qr/The underlying market has moved too much since you priced the contract. The contract price has changed from GBP9.40 to GBP10.00./,
            'price move - msg to client'
        );

        # amount_type = payout, price increase < allowed move
        my $price = $contract->ask_price - ($allowed_move * $contract->payout / 2);
        $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            action   => 'BUY',
            price    => $price,
        });

        $error = $transaction->_validate_trade_pricing_adjustment;
        is($error, undef, 'BUY price increase within allowable move');
        cmp_ok($transaction->price, '==', $price, 'BUY with original price');

        # amount_type = payout, price decrease => better execution price
        $price = $contract->ask_price + ($allowed_move * $contract->payout * 2);
        $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            action   => 'BUY',
            price    => $price,
        });
        $error = $transaction->_validate_trade_pricing_adjustment;
        is($error, undef, 'BUY price decrease, better execution price');
        cmp_ok($transaction->price, '<', $price, 'BUY with lower price');

        $mock_contract->unmock_all;
    };

    subtest 'check payout move' => sub {
        $mock_contract->mock('payout', sub { 100 });
        $mock_contract->mock(
            'commission_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'commission_markup',
                    description => 'fake commission markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0.01,
                });
            });
        $mock_contract->mock(
            'risk_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'risk_markup',
                    description => 'fake risk markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0,
                });
            });
        my $allowed_move = 0.01 * 0.50;
        my $ask_cv       = Math::Util::CalculatedValue::Validatable->new({
            name        => 'ask_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 0.1 + $allowed_move + 0.001,
        });
        $mock_contract->mock('ask_probability', sub { $ask_cv });
        $mock_contract->mock('payout',          sub { 10 / $ask_cv->amount });

        my $contract = produce_contract({
            underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
            bet_type     => 'FLASHU',
            currency     => 'GBP',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            current_tick => $tick,
            barrier      => 'S0P',
        });

        # amount_type = stake, payout decrease > allowed move
        my $transaction = BOM::Product::Transaction->new({
            client      => $client,
            contract    => $contract,
            action      => 'BUY',
            price       => 10,
            payout      => 100,
            amount_type => 'stake',
        });
        my $error = $transaction->_validate_trade_pricing_adjustment;
        is($error->get_type, 'PriceMoved', 'Payout move too much opposite favour of client');
        like(
            $error->{-message_to_client},
            qr/The underlying market has moved too much since you priced the contract. The contract payout has changed from GBP100.00 to GBP94.34./,
            'payout move - msg to client'
        );
        $ask_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'ask_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 0.1 + $allowed_move - 0.001,
        });
        $mock_contract->mock('ask_probability', sub { $ask_cv });
        $mock_contract->mock('payout',          sub { 10 / $ask_cv->amount });

        # amount_type = stake, payout decrease within range of allowed move
        $transaction = BOM::Product::Transaction->new({
            client      => $client,
            contract    => $contract,
            action      => 'BUY',
            price       => 10,
            payout      => 100,
            amount_type => 'stake',
        });
        $error = $transaction->_validate_trade_pricing_adjustment;
        is($error, undef, 'BUY decrease within allowable move');
        cmp_ok($transaction->payout, '==', 100, 'BUY with original payout');
        # amount_type = stake, payout increase within  range of allowed move
        $ask_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'ask_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 0.1 - $allowed_move + 0.001,
        });
        $mock_contract->mock('ask_probability', sub { $ask_cv });
        $mock_contract->mock('payout',          sub { 10 / $ask_cv->amount });

        $transaction = BOM::Product::Transaction->new({
            client      => $client,
            contract    => $contract,
            action      => 'BUY',
            price       => 10,
            payout      => 100,
            amount_type => 'stake',
        });
        $error = $transaction->_validate_trade_pricing_adjustment;
        is($error, undef, 'BUY decrease within allowable move');
        cmp_ok($transaction->payout, '==', 100, 'BUY with original payout');

        # amount_type = stake, payout increase => better execution price
        $ask_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'ask_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 0.1 - $allowed_move - 0.001,
        });
        $mock_contract->mock('ask_probability', sub { $ask_cv });
        $mock_contract->mock('payout', sub { roundnear(0.001, 10 / $ask_cv->amount) });

        $transaction = BOM::Product::Transaction->new({
            client      => $client,
            contract    => $contract,
            action      => 'BUY',
            price       => 10,
            payout      => 100,
            amount_type => 'stake',
        });
        $error = $transaction->_validate_trade_pricing_adjustment;
        is($error, undef, 'payout increase, better execution price');
        cmp_ok($transaction->payout, '>',  100,     'BUY with higher payout');
        cmp_ok($transaction->payout, '==', 106.383, 'payout');

        $mock_contract->unmock_all;
    };

};

subtest 'SELL - sell pricing adjustment' => sub {
    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');

    subtest 'do not allow move if recomputed is 0' => sub {
        $mock_contract->mock('bid_price', sub { 100 });
        $mock_contract->mock(
            'commission_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'commission_markup',
                    description => 'fake commission markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0.01,
                });
            });
        $mock_contract->mock(
            'risk_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'risk_markup',
                    description => 'fake risk markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0,
                });
            });
        my $ask_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'bid_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 1
        });
        $mock_contract->mock('bid_probability', sub { $ask_cv });
        my $allowed_move = 0.01 * 0.80;

        my $contract = produce_contract({
            underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
            bet_type     => 'CALL',
            currency     => 'GBP',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $price = $contract->bid_price - ($allowed_move * $contract->payout) + 0.1;
        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            action   => 'SELL',
            price    => $price,
        });
        my $error = $transaction->_validate_sell_pricing_adjustment;
        is($error, undef, 'no error');
        cmp_ok($transaction->price, '==', 100, 'SELL at the recomputed price');
    };

    subtest 'check price move' => sub {
        $mock_contract->mock('bid_price', sub { 10 });
        $mock_contract->mock(
            'commission_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'commission_markup',
                    description => 'fake commission markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0.01,
                });
            });
        $mock_contract->mock(
            'risk_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'risk_markup',
                    description => 'fake risk markup',
                    set_by      => 'BOM::Product::Contract',
                    base_amount => 0,
                });
            });
        my $bid_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'bid_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 0.1
        });
        $mock_contract->mock('bid_probability', sub { $bid_cv });

        my $allowed_move = 0.01 * 0.80;

        my $contract = produce_contract({
            underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
            bet_type     => 'FLASHU',
            currency     => 'GBP',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            current_tick => $tick,
            barrier      => 'S0P',
        });

        # amount_type = payout, sell price increase > allowed move
        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            action   => 'SELL',
            price    => $contract->bid_price + ($allowed_move * $contract->payout + 0.1),
        });

        my $error = $transaction->_validate_sell_pricing_adjustment;
        is($error->get_type, 'PriceMoved', 'Price move too much opposite favour of client');
        like(
            $error->{-message_to_client},
            qr/The underlying market has moved too much since you priced the contract. The contract sell price has changed from GBP10.90 to GBP10.00./,
            'price move - msg to client'
        );

        # amount_type = payout, sell price decrease < allowed move
        my $price = $contract->bid_price + ($allowed_move * $contract->payout - 0.1);
        $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            action   => 'SELL',
            price    => $price,
        });

        $error = $transaction->_validate_sell_pricing_adjustment;
        is($error, undef, 'SELL price descrease within allowable move');
        cmp_ok($transaction->price, '==', $price, 'SELL with original price');

        # amount_type = payout, sell price increase => better execution price
        $price = $contract->bid_price - ($allowed_move * $contract->payout * 2);
        $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            action   => 'SELL',
            price    => $price,
        });
        $error = $transaction->_validate_sell_pricing_adjustment;
        is($error, undef, 'SELL price increase, better execution price');
        cmp_ok($transaction->price, '>', $price, 'SELL with higher price');

        $mock_contract->unmock_all;
    };

    subtest 'price is undefined' => sub {
        my $mocked = Test::MockModule->new('BOM::Product::Contract');
        $mocked->mock('bid_price', sub { return 50 });
        my $contract = produce_contract({
            underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
            bet_type     => 'CALL',
            currency     => 'GBP',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $transaction = BOM::Product::Transaction->new({
            client   => $client,
            contract => $contract,
            action   => 'SELL',
            price    => undef,
        });
        my $error = $transaction->_validate_sell_pricing_adjustment;
        is($error, undef, 'no error');
        cmp_ok($transaction->price, '==', 50, 'SELL at the recomputed price');
    };
};

subtest 'Purchase Sell Contract' => sub {
    plan tests => 4;

    my $client = BOM::Platform::Client->new({loginid => 'CR2002'});
    $client = BOM::Platform::Client::get_instance({'loginid' => $client->loginid});
    my $mocked_client = Test::MockModule->new('BOM::Platform::Client');
    $mocked_client->mock('residence', sub { return 'al' });
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

    my $bet_type = 'DOUBLEUP';
    $contract = produce_contract({
        underlying   => 'R_50',
        bet_type     => $bet_type,
        currency     => $currency,
        payout       => 100,
        date_start   => $now,
        date_expiry  => $expiry,
        entry_tick   => $random_tick,
        current_tick => $random_tick,
        barrier      => 'S0P',
    });

    my $bpt = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract,
        price    => $contract->ask_price,
    });

    $ENV{REQUEST_STARTTIME} = $now->epoch - 1;
    my $error = $bpt->buy;
    is($error, undef, 'Able to purchase the contract successfully');

    my $trx = $bpt->transaction_record;
    my $fmb = $trx->financial_market_bet;

    ok($trx->account_id, 'can retrieve the trx db record');
    ok($fmb->account_id, 'can retrieve the fmb db record');

    set_absolute_time($now->epoch + 61);
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
        entry_tick   => $current_tick,
        current_tick => $current_tick,
        exit_tick    => $current_tick,
        barrier      => 'S0P',
    });
    my $mocked = Test::MockModule->new('BOM::Product::Transaction');
    $mocked->mock('_validate_sell_pricing_adjustment', sub { });
    $error = BOM::Product::Transaction->new({
            client      => $client,
            contract    => $contract,
            price       => $contract->bid_price,
            contract_id => $bpt->contract_id,
        })->sell;

    is($error, undef, 'Able to sell the contract successfully');
};

subtest 'validate stake limit' => sub {
    my $contract = produce_contract({
        underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
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
    my $transaction = BOM::Product::Transaction->new({
        client      => $client,
        contract    => $contract,
        action      => 'BUY',
        price       => 0.5,
        payout      => 100,
        amount_type => 'stake',
    });
    ok !$transaction->_validate_stake_limit, 'can buy with minimum stake of 0.5 for non MF broker';
    $contract->mock('ask_price', sub { 0.49 });
    lives_ok {
        my $err = $transaction->_validate_stake_limit;
        like($err->{-message_to_client}, qr/This contract's price is/, 'correct error message');
    }
    'error out on 0.49 stake for non MF borker';
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
    $contract->mock('ask_price', sub { 5 });
    $transaction = BOM::Product::Transaction->new({
        client      => $client,
        contract    => $contract,
        action      => 'BUY',
        price       => 5,
        payout      => 100,
        amount_type => 'stake',
    });
    ok !$transaction->_validate_stake_limit, 'can buy with minimum stake of 5 for MF broker';
    $contract->mock('ask_price', sub { 4.9 });
    lives_ok {
        my $err = $transaction->_validate_stake_limit;
        like($err->{-message_to_client}, qr/This contract's price is/, 'correct error message');
    }
    'error out on 4.9 stake for MF borker';
};

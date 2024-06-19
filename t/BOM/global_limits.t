#!/usr/bin/perl

use strict;
use warnings;
use BOM::Test;
use Test::More;
use Test::MockModule;
use Test::FailWarnings;
use Test::Exception;

use Crypt::NamedKeys;
use Date::Utility;
use BOM::Transaction;
use BOM::Transaction::Validation;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Config::Runtime;
use BOM::Database::ClientDB;

use BOM::Test::ContractTestHelper                qw(close_all_open_contracts);
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init :exclude_bet_market_setup);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client                    qw(create_client top_up);
use BOM::Test::Helper::QuantsConfig              qw(create_config delete_all_config);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(
    _validate_trade_pricing_adjustment => sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
$mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

my $mock_transaction = Test::MockModule->new('BOM::Transaction');
$mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

#just to be safe so that sell time does not equal to purchase time
my $now       = Date::Utility->new->minus_time_interval('1s');
my $tick_r100 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_100',
    quote      => 100,
});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
        spot_tick     => Postgres::FeedDB::Spot::Tick->new({epoch => $now->epoch, quote => '133.34'}),
    });

BOM::Config::Runtime->instance->app_config->quants->enable_global_potential_loss(1);
BOM::Config::Runtime->instance->app_config->quants->enable_global_realized_loss(1);
my $cl = create_client('CR');
top_up $cl, 'USD', 5000;

subtest 'symbol not defined' => sub {
    my $contract = produce_contract({
        underlying   => 'R_10',
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        duration     => '1d',
        current_tick => $tick_r100,
        barrier      => 'S10P',
    });

    my $error = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };
    ok $error, 'error is thrown';
    is $error->{'-mesg'},              'Symbol missing in bet.limits_market_mapper table';
    is $error->{'-message_to_client'}, 'Trading is suspended for this instrument.';
};

BOM::Test::Data::Utility::UnitTestDatabase::setup_db_underlying_mapping('limits_market_mapper');
BOM::Test::Data::Utility::UnitTestDatabase::setup_db_underlying_mapping('market');

subtest 'global potential loss' => sub {
    close_all_open_contracts('CR');
    ok(BOM::Config::Runtime->instance->app_config->quants->enable_global_potential_loss, 'global potential loss check is turned on');

    BOM::Test::Helper::QuantsConfig::create_config({
        limit_type   => 'global_potential_loss',
        market       => ['synthetic_index'],
        limit_amount => 0
    });

    my $contract = produce_contract({
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        duration     => '1d',
        current_tick => $tick_r100,
        barrier      => 'S10P',
    });

    my $error = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };

    ok $error, 'error is thrown';
    is $error->{'-mesg'}, 'company-wide risk limit reached';
    is $error->{'-message_to_client'},
        'No further trading is allowed on this contract type for the current trading session For more info, refer to our terms and conditions.';

    note("turn off global potential loss check");
    BOM::Config::Runtime->instance->app_config->quants->enable_global_potential_loss(0);

    $error = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };

    ok !$error, 'no error';
    note("turn on global potential loss check");
    BOM::Config::Runtime->instance->app_config->quants->enable_global_potential_loss(1);

    sleep(1);                             # prevent race condition
    close_all_open_contracts('CR', 1);    #close with full payout
    foreach my $config ((
            {limit_amount => 100},
            {
                market            => ['synthetic_index'],
                underlying_symbol => ['R_50'],
                limit_amount      => 49
            },
            {
                market            => ['synthetic_index'],
                underlying_symbol => ['default'],
                limit_amount      => 99
            }))
    {
        BOM::Test::Helper::QuantsConfig::create_config({
            limit_type => 'global_potential_loss',
            %$config,
        });
    }

    my $args = {
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        duration     => '1d',
        current_tick => $tick_r100,
        barrier      => 'S10P',
    };
    # R_100 will hit underlying default limit
    $contract = produce_contract($args);

    $error = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };

    ok $error, 'error is thrown';
    is $error->{'-mesg'}, 'company-wide risk limit reached';
    is $error->{'-message_to_client'},
        'No further trading is allowed on this contract type for the current trading session For more info, refer to our terms and conditions.';

    sleep(1);
    close_all_open_contracts('CR', 1);    # close with full payout
    $contract = produce_contract({%$args, underlying => 'R_50'});
    $error    = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };

    ok $error, 'error is thrown';
    is $error->{'-mesg'}, 'company-wide risk limit reached';
    is $error->{'-message_to_client'},
        'No further trading is allowed on this contract type for the current trading session For more info, refer to our terms and conditions.';

    $contract = produce_contract({%$args, underlying => 'frxUSDJPY'});
    $error    = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };
    ok !$error, 'no error';
};

subtest 'global realized loss' => sub {
    delete_all_config();
    close_all_open_contracts('CR', 1);    #1 close with full payout

    # disable global potential loss
    BOM::Config::Runtime->instance->app_config->quants->enable_global_potential_loss(0);
    # current loss for R_100-callput-daily-non_atm is 100 USD
    ok(BOM::Config::Runtime->instance->app_config->quants->enable_global_realized_loss, 'global realized loss check is turned on');

    BOM::Test::Helper::QuantsConfig::create_config({
        limit_type   => 'global_realized_loss',
        limit_amount => 0
    });
    my $contract = produce_contract({
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        duration     => '1m',
        current_tick => $tick_r100,
        barrier      => 'S0P',
    });
    my $error = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };

    ok $error, 'error is thrown';
    is $error->{'-mesg'}, 'company-wide risk limit reached';
    is $error->{'-message_to_client'},
        'No further trading is allowed on this contract type for the current trading session For more info, refer to our terms and conditions.';

    note("turn off global realized loss check");
    BOM::Config::Runtime->instance->app_config->quants->enable_global_realized_loss(0);

    $error = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };
    ok !$error, 'no error';
    note("turn on global realized loss check");
    BOM::Config::Runtime->instance->app_config->quants->enable_global_realized_loss(1);

    sleep(1);    # prevent race condition
    close_all_open_contracts('CR', 1);
    foreach my $config ((
            {limit_amount => 299},
            {
                market            => ['synthetic_index'],
                underlying_symbol => ['R_50'],
                limit_amount      => 49
            },
            {
                market            => ['synthetic_index'],
                underlying_symbol => ['default'],
                limit_amount      => 149
            }))
    {
        BOM::Test::Helper::QuantsConfig::create_config({
            limit_type => 'global_realized_loss',
            %$config,
        });
    }

    my $args = {
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        duration     => '1d',
        current_tick => $tick_r100,
        barrier      => 'S10P',
    };
    # R_100 will hit underlying default limit
    $contract = produce_contract($args);

    $error = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
        sleep(1);    # avoid fmb constraint
        close_all_open_contracts('CR', 1);
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };
    ok $error, 'error is thrown';
    is $error->{'-mesg'}, 'company-wide risk limit reached';
    is $error->{'-message_to_client'},
        'No further trading is allowed on this contract type for the current trading session For more info, refer to our terms and conditions.';

    sleep(1);
    close_all_open_contracts('CR');
    $contract = produce_contract({%$args, underlying => 'R_50'});
    $error    = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
        sleep(1);
        close_all_open_contracts('CR', 1);
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };

    ok $error, 'error is thrown';
    is $error->{'-mesg'}, 'company-wide risk limit reached';
    is $error->{'-message_to_client'},
        'No further trading is allowed on this contract type for the current trading session For more info, refer to our terms and conditions.';

    $contract = produce_contract({%$args, underlying => 'frxUSDJPY'});
    $error    = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };

    ok $error, 'no error';
    is $error->{'-mesg'}, 'company-wide risk limit reached';
    is $error->{'-message_to_client'},
        'No further trading is allowed on this contract type for the current trading session For more info, refer to our terms and conditions.';

    BOM::Test::Helper::QuantsConfig::create_config({
        limit_type   => 'global_realized_loss',
        limit_amount => 300
    });
    $error = do {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };
    ok !$error, 'no error';
};

done_testing();


#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Exception;
use Test::Deep;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory                qw(produce_contract);
use BOM::Config::Runtime;

initialize_realtime_ticks_db();
my $now    = Date::Utility->new('10-Mar-2015');
my $symbol = 'R_100';

my $epoch = $now->epoch;
BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [1763.00, $epoch,     $symbol],
    [1780.00, $epoch + 1, $symbol],
    [1958.00, $epoch + 2, $symbol],
    [1390.00, $epoch + 3, $symbol],
);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $args = {
    bet_type     => 'TURBOSLONG',
    underlying   => $symbol,
    date_start   => $now,
    date_pricing => $now,
    duration     => '7d',
    currency     => 'USD',
    amount_type  => 'stake',
    amount       => 100,
    barrier      => '-73.00',
};

my $mocked_contract = Test::MockModule->new('BOM::Product::Contract::Turboslong');
$mocked_contract->mock('strike_price_choices', sub { return ['-73.00', '-85.00', '-100.00'] }, '_max_allowable_take_profit',
    sub { return '1000.00' });

subtest 'config' => sub {
    my $c = eval { produce_contract($args); };

    isa_ok $c, 'BOM::Product::Contract::Turboslong';
    is $c->code,          'TURBOSLONG', 'code TURBOSLONG';
    is $c->pricing_code,  'TURBOSLONG', 'pricing code TURBOSLONG';
    is $c->category_code, 'turbos',     'category turbos';
    ok $c->is_path_dependent,       'is path dependent';
    ok !defined $c->pricing_engine, 'price engine is udefined';
    ok !$c->is_intraday,            'is not intraday';
    isa_ok $c->barrier, 'BOM::Product::Contract::Strike';
    cmp_ok $c->barrier->as_absolute, '==', 1690, 'correct absolute barrier';
    is $c->ask_price, 100, 'ask_price is 100';
    ok $c->pricing_new, 'this is a new contract';
    is $c->n_max, 113.442994895065, 'correct n_max';

    my $barriers = $c->strike_price_choices;
    is $barriers->[0],                               '-73.00',   'correct first barrier';
    is $barriers->[1],                               '-85.00',   'correct 5th barrier';
    is $barriers->[-1],                              '-100.00',  'correct last barrier';
    is sprintf("%.5f", $c->bid_probability->amount), '72.60042', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '73.39958', 'correct ask probability';
};

subtest 'number of contracts' => sub {
    # number of contracts = stake / options ask price
    # must be the same
    my $c = produce_contract($args);
    ok $c->pricing_new, 'this is a new contract';
    is $c->number_of_contracts, '1.362405', 'correct number_of_contracts';
    ok !$c->is_expired, 'not expired (obviously but just be safe)';
    is $c->buy_commission, 0.544393266571043, 'buy commission';

    $args->{currency}     = 'USD';
    $args->{date_pricing} = $now->plus_time_interval('1s');
    $c                    = produce_contract($args);
    cmp_ok sprintf("%.6f", $c->number_of_contracts), '==', '1.362405', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price,       '122.07',          'has bid price';
    is $c->sell_commission, 0.549642662788687, 'sell commission when contract is not expired';

    $args->{date_pricing} = $now->plus_time_interval('2s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.6f", $c->number_of_contracts), '==', '1.362405', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '364.52', 'has bid price, and higher because spot is higher now';

    $args->{date_pricing} = $now->plus_time_interval('3s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.6f", $c->number_of_contracts), '==', '1.362405', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok $c->is_expired,   'expired';
    is $c->bid_price,       '0.00', 'does not have bid price';
    is $c->sell_commission, 0,      'no sell commission when contract is expired';
};

subtest 'take_profit' => sub {
    $args->{date_pricing} = $now;

    my $c = produce_contract($args);
    is $c->take_profit, undef, 'take_profit is undef';

    subtest 'mininum allowed amount' => sub {
        $args->{limit_order} = {
            take_profit => '0',
        };
        $c = produce_contract($args);
        ok !$c->is_valid_to_buy, 'invalid to buy';
        is $c->primary_validation_error->message, 'take profit too low', 'message - take profit too low';
        is $c->primary_validation_error->message_to_client->[0], 'Please enter a take profit amount that\'s higher than [_1].',
            'message - Please enter a take profit amount that\'s higher than [_1].';
        is $c->primary_validation_error->message_to_client->[1], '0.00';
    };

    subtest 'maximum allowed amount' => sub {
        $args->{limit_order} = {
            take_profit => '1000000',
        };
        $c = produce_contract($args);
        ok !$c->is_valid_to_buy, 'invalid to buy';
        is $c->primary_validation_error->message, 'take profit too high', 'message - take profit too low';
        is $c->primary_validation_error->message_to_client->[0], 'Please enter a take profit amount that\'s lower than [_1].',
            'message - Please enter a take profit amount that\'s higher than [_1].';
        is $c->primary_validation_error->message_to_client->[1], '1000.00';
    };

    subtest 'validate amount as decimal' => sub {
        $args->{limit_order} = {
            take_profit => '10.451',
        };
        $c = produce_contract($args);
        ok !$c->is_valid_to_buy, 'invalid to buy';
        is $c->primary_validation_error->message,                'too many decimal places';
        is $c->primary_validation_error->message_to_client->[0], 'Only [_1] decimal places allowed.', 'Only [_1] decimal places allowed.';
        is $c->primary_validation_error->message_to_client->[1], '2';
    };

    subtest 'pricing_new' => sub {
        $args->{limit_order} = {
            take_profit => '26.97',
        };
        $c = produce_contract($args);
        ok $c->is_valid_to_buy, 'valid to buy';
        is $c->take_profit->{amount},      '26.97';
        is $c->take_profit->{date}->epoch, $c->date_pricing->epoch;

        $args->{limit_order} = {
            take_profit => '50',
        };
        $c = produce_contract($args);
        is $c->take_profit->{amount},      '50';
        is $c->take_profit->{date}->epoch, $c->date_pricing->epoch;
    };

    subtest 'non-pricing new' => sub {
        delete $args->{date_pricing};

        $args->{limit_order} = {
            take_profit => {
                order_amount => 5.11,
                order_date   => $now->epoch,
            }};
        $c = produce_contract($args);
        ok !$c->pricing_new, 'non pricing_new';
        is $c->take_profit->{amount},      '5.11';
        is $c->take_profit->{date}->epoch, $now->epoch;

        delete $args->{limit_order};
    };

    subtest 'unset take profit with proper hit tick parameters' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [1763.00, $epoch,     $symbol],
            [1764.00, $epoch + 1, $symbol],    # this would have hit the barrier with 0 take profit
            [1762.00, $epoch + 2, $symbol],
            [1761.00, $epoch + 3, $symbol],
        );
        $args->{limit_order} = {
            take_profit => {
                order_amount => undef,
                order_date   => $now->epoch,
            }};
        $args->{date_pricing} = $now->epoch + 30;
        $c = produce_contract($args);
        ok $c->take_profit,            'take profit is defined';
        ok !$c->take_profit->{amount}, 'take profit amount is undef';
        ok !$c->is_expired,            'not expired';
    };

    subtest 'take profit lookup date' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [1763.00, $epoch,     $symbol],
            [1772.00, $epoch + 1, $symbol],    # this would have hit the barrier with 10 take profit
            [1762.00, $epoch + 2, $symbol],
            [1761.00, $epoch + 3, $symbol],
        );
        $args->{limit_order} = {
            take_profit => {
                order_amount => 10,
                order_date   => $epoch,
            }};
        $args->{date_pricing} = $now->epoch + 30;
        $c = produce_contract($args);
        ok $c->take_profit, 'take profit is defined';
        is $c->take_profit->{amount},     10,      'take profit amount is 10';
        is $c->take_profit_barrier_value, 1771.15, 'take profit barrier value is 1771.15';
        ok $c->is_expired, 'expired when take profit is set at ' . $epoch;

        $args->{limit_order} = {
            take_profit => {
                order_amount => 10,
                order_date   => $epoch + 2,
            }};
        $c = produce_contract($args);
        ok $c->take_profit, 'take profit is defined';
        is $c->take_profit->{amount},     10,      'take profit amount is 10';
        is $c->take_profit_barrier_value, 1771.15, 'take profit barrier value is 1771.15';
        ok !$c->is_expired, 'not expired when take profit is set at ' . $c->take_profit->{date}->epoch;
    };
};

subtest 'expired and not breached barrier' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [1763.00, $epoch,       $symbol],
        [1780.00, $epoch + 60,  $symbol],
        [1950.00, $epoch + 119, $symbol],
        [1958.00, $epoch + 120, $symbol],
        [1390.00, $epoch + 121, $symbol],
    );

    delete $args->{limit_order};
    $args->{duration}     = '2m';
    $args->{date_pricing} = $now;

    my $c = produce_contract($args);
    ok $c->pricing_new, 'this is a new contract';
    ok !$c->is_expired, 'not expired (obviously but just be safe)';

    $args->{date_pricing} = $now->plus_time_interval('60s');
    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    is $c->bid_price, '122.07', 'has bid price';

    $args->{date_pricing} = $now->plus_time_interval('2m');
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    is $c->bid_price, '365.12', 'payoff higher than bid price because in expiry time no commission';

    $args->{date_pricing} = $now->plus_time_interval('125s');
    $c = produce_contract($args);
    ok !$c->pricing_new, 'contract is new';
    ok $c->is_expired,   'expired';
    is $c->bid_price, '365.12', 'win payoff';
};

subtest 'shortcode' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s')->epoch;
    my $c         = produce_contract($args);
    my $shortcode = 'TURBOSLONG_R_100_100.00_' . $now->epoch . '_' . $now->plus_time_interval('2m')->epoch . '_S-7300P_1.362405_1425945600';

    my $c_shortcode;
    lives_ok {
        $c_shortcode = produce_contract($shortcode, 'USD');
    }
    'does not die trying to produce contract from short code';

    is $c->shortcode,            $shortcode,                         'same short code';
    is $c->code,                 $c_shortcode->code,                 'same code';
    is $c->pricing_code,         $c_shortcode->pricing_code,         'same pricing code';
    is $c->barrier->as_absolute, $c_shortcode->barrier->as_absolute, 'same strike price';
    is $c->date_start->epoch,    $c_shortcode->date_start->epoch,    'same date start';
    is $c->number_of_contracts,  $c_shortcode->number_of_contracts,  'same number of contracts';
    is $c->entry_tick->epoch,    $c_shortcode->entry_tick->epoch,    'same entry tick epoch';
};

# entry_epoch was not included inside the shortcode at first. Because there are some contracts inside DB
# with this old format, we should still be able to reproduce contracts with those parameters only.
subtest 'shortcode (legacy)' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s')->epoch;
    my $c         = produce_contract($args);
    my $shortcode = 'TURBOSLONG_R_100_100.00_' . $now->epoch . '_' . $now->plus_time_interval('2m')->epoch . '_S-7300P_1.362405';

    my $c_shortcode;
    lives_ok {
        $c_shortcode = produce_contract($shortcode, 'USD');
    }
    'does not die trying to produce contract from short code';

    is $c->code,                 $c_shortcode->code,                 'same code';
    is $c->pricing_code,         $c_shortcode->pricing_code,         'same pricing code';
    is $c->barrier->as_absolute, $c_shortcode->barrier->as_absolute, 'same strike price';
    is $c->date_start->epoch,    $c_shortcode->date_start->epoch,    'same date start';
    is $c->number_of_contracts,  $c_shortcode->number_of_contracts,  'same number of contracts';
};

subtest 'longcode' => sub {
    my $c = produce_contract($args);

    is_deeply(
        $c->longcode,
        [
            "For 'Long', you receive a payout on [_3] if the spot price of [_1] never touches or drops below [_4]. Your payout is equal to [_5] multiplied by the absolute difference between the final price and [_4]. You may choose to sell the contract up until 15 seconds before [_3], and receive a contract value.",
            ['Volatility 100 Index'],
            ['contract start time'],
            '10-Mar-15 00:02:00GMT',
            ['entry spot minus [_1]', '73.00'],
            '1.362405'
        ]);

    delete $args->{duration};
    $args->{duration} = '5t';
    my $tick_c = produce_contract($args);

    is_deeply(
        $tick_c->longcode,
        [
            "For 'Long', you receive a payout in [plural,_3,%d tick,%d ticks] if the spot price of [_1] never touches or drops below [_4]. Your payout is equal to [_5] multiplied by the absolute difference between the final price and [_4]. If you choose your duration in number of ticks, you won't be able to terminate your contract early.",
            ['Volatility 100 Index'],
            ['first tick'],
            [5],
            ['entry spot minus [_1]', '73.00'],
            '1.362405'
        ],
        'longcode matches'
    );
};

subtest 'entry and exit tick' => sub {
    lives_ok {
        $args->{duration}     = '2m';
        $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Turboslong';
        is $c->code, 'TURBOSLONG';
        ok $c->is_intraday,             'is intraday';
        ok !defined $c->pricing_engine, 'price engine is udefined';
        cmp_ok $c->barrier->as_absolute, 'eq', '1690.00',  'correct absolute barrier (it will be pipsized) ';
        cmp_ok $c->entry_tick->quote,    'eq', '1763',     'correct entry tick';
        cmp_ok $c->current_spot,         'eq', '1763.00',  'correct current spot (it will be pipsized)';
        cmp_ok $c->number_of_contracts,  'eq', '1.362405', 'number of contracts are correct';

        $args->{date_pricing} = $now->plus_time_interval('2m');
        $c = produce_contract($args);
        ok $c->bid_price, 'ok bid price';
        cmp_ok $c->number_of_contracts, 'eq', '1.362405', 'number of contracts are correct';
        cmp_ok sprintf("%.2f", $c->current_spot),         'eq', '1958.00', 'correct spot price';
        cmp_ok sprintf("%.2f", $c->barrier->as_absolute), 'eq', '1690.00', 'correct strike';

        ok $c->is_expired, 'expired';
        cmp_ok sprintf("%.2f", $c->value), 'eq', '365.12', '(strike - spot) * number of contracts';
        ok $c->exit_tick,                                   'has exit tick';
        ok $c->exit_tick->quote > $c->barrier->as_absolute, 'exit tick is bigger than strike price';
        ok $c->value > 0,                                   'contract value is bigger than 0, exit tick is bigger than strike price';
        cmp_ok sprintf("%.2f", $c->value), 'eq', '365.12', 'correct payout';
        cmp_ok $c->exit_tick->quote,       'eq', '1958',   'correct exit tick';
    }
    'winning the contract';

    lives_ok {
        my $c = produce_contract($args);

        $args->{duration}     = '20m';
        $args->{date_pricing} = $now->plus_time_interval('20m');
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 1199,
            quote      => 68000.58,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 1200,
            quote      => 69330.39,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 1201,
            quote      => 69440.39,
        });
        $c = produce_contract($args);
        ok $c->is_expired,                                  'expired';
        ok $c->exit_tick,                                   'has exit tick';
        ok $c->exit_tick->quote > $c->barrier->as_absolute, 'exit tick is smaller than strike price';
        ok $c->value == 0,                                  'contract is worthless, exit tick is smaller than strike price';
        cmp_ok $c->exit_tick->quote, 'eq', '69330.39', 'correct exit tick';
    }
    'losing the contract';
};

subtest 'special test case' => sub {
    $epoch = $now->epoch;
    my $symbol_R25 = 'R_25';
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [10138.979, $epoch,               $symbol_R25],
        [10139.829, $epoch + 5 * 60,      $symbol_R25],
        [10140.829, $epoch + 10 * 60,     $symbol_R25],
        [10141.829, $epoch + 10 * 60 + 1, $symbol_R25],
    );

    $args->{barrier}      = 10123.5190;
    $args->{duration}     = '60m';
    $args->{date_pricing} = $now;
    $args->{underlying}   = $symbol_R25;

    my $c = produce_contract($args);
    ok $c->pricing_new, 'this is a new contract';
    ok !$c->is_expired, 'not expired (obviously but just be safe)';

    $args->{date_pricing} = $now->plus_time_interval('5m');
    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    is $c->bid_price, '98.13', 'has bid price';
};

subtest 'consistent sell tick' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([10138.979, $now->epoch, $symbol], [10139.829, $now->epoch + 17999, $symbol]);

    $args->{underlying}   = $symbol;
    $args->{duration}     = '7h';
    $args->{date_pricing} = $now->plus_time_interval('5h');
    my $c                    = produce_contract($args);
    my $sold_at_market_price = $c->bid_price;
    is $c->current_tick->epoch, $now->epoch + 17999, 'correct tick';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $symbol,
        epoch      => $now->epoch + 18000,
        quote      => 10141.69,
    });

    # oops, sold at market, but time is t + 1
    $args->{sell_price} = $sold_at_market_price;
    $args->{sell_time}  = $now->epoch + 18000;
    $c                  = produce_contract($args);

    is $c->close_tick->quote, 10139.829,           'correct tick';
    is $c->close_tick->epoch, $now->epoch + 17999, 'correct tick';

};

subtest 'special test for take profit discrepancies' => sub {
    my $epoch_date_start   = 1699519419;
    my $epoch_date_pricing = 1699519608;
    my $epoch_date_expiry  = 1699551819;
    my $special_args       = {
        bet_type            => 'TURBOSLONG',
        underlying          => $symbol,
        date_start          => $epoch_date_start,
        date_pricing        => $epoch_date_pricing,
        duration            => '9h',
        currency            => 'USD',
        amount_type         => 'stake',
        amount              => 500,
        number_of_contracts => 71.56449,
        bid_spread          => 0.000165607364228642,
        barrier             => 2156.68,
    };
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [2163.32, $epoch_date_start,   $symbol],
        [2165.43, $epoch_date_pricing, $symbol],
        [2166.71, $epoch_date_expiry,  $symbol],
    );
    $special_args->{limit_order} = {
        take_profit => {
            order_amount => 100,
            order_date   => $epoch_date_start,
        }};

    my $c = produce_contract($special_args);
    ok $c->take_profit, 'take profit is defined';
    is $c->take_profit->{amount},     100,              'take profit amount is 100';
    is $c->hit_tick->{quote},         2165.43,          'hit tick at 2165.43';
    is $c->take_profit_barrier_value, 2165.43,          'take profit barrier value is 2165.43';
    is $c->sell_commission,           25.6638243959644, 'bid_spread charged on take_profit_hit';
};

done_testing();

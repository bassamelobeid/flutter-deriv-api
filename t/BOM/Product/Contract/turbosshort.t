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
my $symbol = '1HZ25V';

my $epoch = $now->epoch;
BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [351093.00, $epoch,     $symbol],
    [351559.00, $epoch + 1, $symbol],
    [346002.00, $epoch + 2, $symbol],
    [348070.00, $epoch + 3, $symbol],
    [351550.00, $epoch + 4, $symbol],
    [349423.00, $epoch + 5, $symbol],
    [353650.00, $epoch + 6, $symbol],
);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $args = {
    bet_type     => 'TURBOSSHORT',
    underlying   => $symbol,
    date_start   => $now,
    date_pricing => $now,
    duration     => '30d',
    currency     => 'USD',
    amount_type  => 'stake',
    amount       => 20,
    barrier      => '351610.00',
};

subtest 'config' => sub {
    my $c = eval { produce_contract($args); };

    isa_ok $c, 'BOM::Product::Contract::Turbosshort';
    is $c->code,          'TURBOSSHORT', 'code TURBOSSHORT';
    is $c->pricing_code,  'TURBOSSHORT', 'pricing code TURBOSSHORT';
    is $c->category_code, 'turbos',      'category turbos';
    ok $c->is_path_dependent,       'is path dependent';
    ok !defined $c->pricing_engine, 'price engine is udefined';
    ok !$c->is_intraday,            'is not intraday';
    isa_ok $c->barrier, 'BOM::Product::Contract::Strike';
    cmp_ok $c->barrier->as_absolute, '==', 351610, 'correct absolute barrier';
    is $c->ask_price, 20, 'ask_price is correct';
    ok $c->pricing_new, 'this is a new contract';
    is $c->n_max, 2.84824818495384, 'correct n_max';

    my $barriers = $c->strike_price_choices;
    is $barriers->[0],                               '+270.72',   'correct first barrier';
    is $barriers->[5],                               '+1487.6',   'correct 5th barrier';
    is $barriers->[-1],                              '+175546.5', 'correct last barrier';
    is sprintf("%.5f", $c->bid_probability->amount), '531.06700', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '502.93300', 'correct ask probability';
};

subtest 'number of contracts' => sub {
    # number of contracts = stake / options ask price
    # must be the same
    my $c = produce_contract($args);
    ok $c->pricing_new, 'this is a new contract';
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.03766', 'correct number of contracts';
    ok !$c->is_expired, 'not expired (obviously but just be safe)';
    is $c->buy_commission, 0.529763095440703, 'correct buy commission';

    $args->{date_pricing} = $now->plus_time_interval('1s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.03766', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price,       '1.39',            'has bid price';
    is $c->sell_commission, 0.530466241337873, 'correct sell commission';

    $args->{date_pricing} = $now->plus_time_interval('2s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.03766', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '210.68', 'has bid price, and higher because spot is higher now';

    $args->{date_pricing} = $now->plus_time_interval('3s');
    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    is $c->bid_price, '132.79', 'has bid price, and higher because spot is higher now';

    $args->{date_pricing} = $now->plus_time_interval('31d');
    $c = produce_contract($args);
    ok $c->is_expired, 'contract is expired, this is a 30d contract';
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.03766', 'correct number of contracts';
};

subtest 'shortcode' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s')->epoch;
    $args->{duration}     = '5m';
    my $c         = produce_contract($args);
    my $shortcode = 'TURBOSSHORT_1HZ25V_20.00_' . $now->epoch . '_' . $now->plus_time_interval('5m')->epoch . '_351610000000_0.03766_1425945600';

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

subtest 'longcode' => sub {
    my $c = produce_contract($args);

    is_deeply(
        $c->longcode,
        [
            "For 'Short', you receive a payout on [_3] if the spot price of [_1] never touches or rises above [_4]. Your payout is equal to [_5] multiplied by the absolute difference between the final price and [_4]. You may choose to sell the contract up until 15 seconds before [_3], and receive a contract value.",
            ['Volatility 25 (1s) Index'],
            ['contract start time'],
            '10-Mar-15 00:05:00GMT',
            '351610.00',
            '0.03766'
        ],
        'longcode matches'
    );

    delete $args->{duration};
    $args->{duration} = '5t';
    my $tick_c = produce_contract($args);

    is_deeply(
        $tick_c->longcode,
        [
            "For 'Short', you receive a payout in [plural,_3,%d tick,%d ticks] if the spot price of [_1] never touches or rises above [_4]. Your payout is equal to [_5] multiplied by the absolute difference between the final price and [_4]. If you choose your duration in number of ticks, you won't be able to terminate your contract early.",
            ['Volatility 25 (1s) Index'],
            ['first tick'],
            [5],
            '351610.00',
            '0.03766'
        ],
        'longcode matches'
    );

};

subtest 'entry and exit tick' => sub {
    lives_ok {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [351093.00, $epoch,     $symbol],
            [351559.00, $epoch + 1, $symbol],
            [346002.00, $epoch + 2, $symbol],
            [348070.00, $epoch + 3, $symbol],
            [351550.00, $epoch + 4, $symbol],
            [351559.00, $epoch + 5, $symbol],
        );

        $args->{duration}     = '6s';
        $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Turbosshort';
        is $c->code, 'TURBOSSHORT';
        ok $c->is_intraday,             'is intraday';
        ok !defined $c->pricing_engine, 'price engine is udefined';
        cmp_ok $c->barrier->as_absolute,                 'eq', '351610.00', 'correct absolute barrier (it will be pipsized) ';
        cmp_ok $c->entry_tick->quote,                    'eq', '351093',    'correct entry tick';
        cmp_ok $c->current_spot,                         'eq', '351093.00', 'correct current spot (it will be pipsized)';
        cmp_ok sprintf("%.3f", $c->number_of_contracts), 'eq', '0.038',     'number of contracts are correct';

        $args->{date_pricing} = $now->plus_time_interval('6s');
        $c = produce_contract($args);
        ok $c->bid_price, 'ok bid price';
        cmp_ok sprintf("%.3f", $c->number_of_contracts),  'eq', '0.038',     'number of contracts are correct';
        cmp_ok sprintf("%.2f", $c->current_spot),         'eq', '351559.00', 'correct spot price';
        cmp_ok sprintf("%.2f", $c->barrier->as_absolute), 'eq', '351610.00', 'correct strike';

        ok $c->is_expired, 'expired';
        cmp_ok sprintf("%.2f", $c->value), 'eq', '1.92', '(strike - spot) * number of contracts';
        ok $c->exit_tick,                                   'has exit tick';
        ok $c->exit_tick->quote < $c->barrier->as_absolute, 'exit tick is lower than strike price';
        ok $c->value > 0,                                   'contract value is bigger than 0, exit tick is bigger than strike price';
        cmp_ok sprintf("%.2f", $c->value), 'eq', '1.92',   'correct payout';
        cmp_ok $c->exit_tick->quote,       'eq', '351559', 'correct exit tick';
    }
    'winning the contract';

    lives_ok {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [351093.00, $epoch,     $symbol],
            [351559.00, $epoch + 1, $symbol],
            [346002.00, $epoch + 2, $symbol],
            [348070.00, $epoch + 3, $symbol],
            [351550.00, $epoch + 4, $symbol],
            [351610.00, $epoch + 5, $symbol],
        );

        $args->{duration}     = '6s';
        $args->{date_pricing} = $now->plus_time_interval('6s');
        my $c = produce_contract($args);
        ok $c->is_expired,                                   'expired';
        ok $c->exit_tick,                                    'has exit tick';
        ok $c->exit_tick->quote <= $c->barrier->as_absolute, 'exit tick is smaller than strike price';
        ok $c->value == 0,                                   'contract is worthless, exit tick is smaller than strike price';
        cmp_ok $c->exit_tick->quote, 'eq', '351610', 'correct exit tick';
    }
    'losing the contract';
};

my $mocked_contract = Test::MockModule->new('BOM::Product::Contract::Turbosshort');
$mocked_contract->mock('strike_price_choices', sub { return ['+73.00', '+85.00', '+100.00'] }, '_max_allowable_take_profit',
    sub { return '1000.00' });

subtest 'take_profit' => sub {
    $args->{date_pricing} = $now;
    $args->{barrier}      = '+73.00';

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
            [1764.00, $epoch + 1, $symbol],
            [1762.00, $epoch + 2, $symbol],
            [1761.00, $epoch + 3, $symbol],    # this would have hit the barrier with 0 take profit
        );
        $args->{limit_order} = {
            take_profit => {
                order_amount => undef,
                order_date   => $now->epoch,
            }};
        $args->{date_pricing} = $now->epoch + 30;
        delete $args->{duration};
        $args->{date_expiry} = $now->epoch + 120;
        $c = produce_contract($args);
        ok $c->take_profit,            'take profit is defined';
        ok !$c->take_profit->{amount}, 'take profit amount is undef';
        ok !$c->is_expired,            'not expired';
    };

    subtest 'take profit lookup date' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [1763.00, $epoch,     $symbol],
            [1725.00, $epoch + 1, $symbol],    # this would have hit the barrier with 10 take profit
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
        is $c->take_profit->{amount},     10,               'take profit amount is 10';
        is $c->take_profit_barrier_value, 1726.32577607076, 'take profit barrier value is 1726.32577607076';
        ok $c->is_expired, 'expired when take profit is set at ' . $epoch;

        $args->{limit_order} = {
            take_profit => {
                order_amount => 10,
                order_date   => $epoch + 2,
            }};
        $c = produce_contract($args);
        ok $c->take_profit, 'take profit is defined';
        is $c->take_profit->{amount},     10,               'take profit amount is 10';
        is $c->take_profit_barrier_value, 1726.32577607076, 'take profit barrier value is 1726.32577607076';
        ok !$c->is_expired, 'not expired when take profit is set at ' . $c->take_profit->{date}->epoch;
    };
};

done_testing();

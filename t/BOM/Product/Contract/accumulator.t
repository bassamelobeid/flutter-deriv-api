#!/etc/rmg/bin/perl

use strict;
use warnings;

use utf8;
use Test::More;
use Test::Exception;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Config::Runtime;

use BOM::Product::ContractFactory qw(produce_contract);
use Finance::Contract::Longcode   qw(shortcode_to_parameters);
use Date::Utility;

my $now    = Date::Utility->new(time);
my $symbol = 'R_100';

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $args = {
    bet_type          => 'ACCU',
    underlying        => $symbol,
    date_start        => $now,
    date_pricing      => $now,
    amount_type       => 'stake',
    amount            => 1,
    growth_rate       => 0.01,
    currency          => 'USD',
    growth_frequency  => 1,
    growth_start_step => 1,
    tick_size_barrier => 0.02,
};

subtest 'config' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, $symbol]);
    my $c = produce_contract($args);

    isa_ok $c, 'BOM::Product::Contract::Accu';
    is $c->code,          'ACCU',        'code ACCU';
    is $c->category_code, 'accumulator', 'category accumulator';
    ok $c->is_path_dependent, 'path dependent';
    is $c->tick_count,      927,  'tick count is 927';
    is $c->ticks_to_expiry, 927,  'ticks to expiry is 927';
    is $c->max_duration,    1000, 'max duration is 1000';
    is $c->ask_price,       1,    'ask_price is 1';
    ok !$c->pricing_engine,      'pricing_engine is undef';
    ok !$c->pricing_engine_name, 'pricing_engine_name is undef';
    ok !$c->payout,              'payout is not defined';
    ok !$c->take_profit,         'take_profit is not defined';
};

subtest 'have duration in user input' => sub {
    $args->{duration} = '10t';

    my $error = exception { produce_contract($args) };
    is $error->message_to_client->[0], 'Invalid input (duration or date_expiry) for this contract type ([_1]).',
        'message to client - User can\'t define duration for [_1].';
    is $error->message_to_client->[1], 'ACCU';

    delete $args->{duration};
    $args->{date_expiry} = Date::Utility->new($now->epoch + 10);

    $error = exception { produce_contract($args) };
    is $error->message_to_client->[0], 'Invalid input (duration or date_expiry) for this contract type ([_1]).',
        'message to client - User can\'t define duration for [_1].';
    is $error->message_to_client->[1], 'ACCU';

    delete $args->{date_expiry};
};

subtest 'shortcode and longcode' => sub {
    my $c = produce_contract($args);

    is $c->shortcode, 'ACCU_R_100_1.00_1_0.01_1_0.02_' . $now->epoch, 'shortcode populated correctly';
    is_deeply(
        $c->longcode,
        ['Win [_2]% of your stake for every tick change in [_1] that does not exceed ± [_3]%.', ['Volatility 100 Index'], ['1'], ['2']],
        'longcode matches'
    );
    is $c->growth_rate, 0.01, 'growth rate is 0.01';
    my $params = shortcode_to_parameters('ACCU_R_100_2.34_2_0.01_1_0.00064889_1653292620', 'USD');
    is $params->{amount_type},       'stake',                                          'acmount_type is stake';
    is $params->{amount},            2.34,                                             'amount is 2.34';
    is $params->{underlying},        'R_100',                                          'underlying is R_100';
    is $params->{growth_start_step}, 2,                                                'growth_start_step is 2';
    is $params->{date_start},        '1653292620',                                     'date_start is set correctly';
    is $params->{tick_size_barrier}, 0.00064889,                                       'tick_size_barrier is set correctly';
    is $params->{growth_frequency},  1,                                                'growth_frequency is 1';
    is $params->{shortcode},         'ACCU_R_100_2.34_2_0.01_1_0.00064889_1653292620', 'shortcode is set';
    is $params->{growth_rate},       0.01,                                             'growth_rate is 0.01';
    is $params->{bet_type},          'ACCU',                                           'bet_type is ACCU';
};

subtest 'barrier' => sub {
    subtest 'pricing_new' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, $symbol], [101, $now->epoch + 1, $symbol]);
        my $c = produce_contract($args);
        is $c->low_barrier->supplied_barrier,  98,  'supplied_barrier is correct';
        is $c->high_barrier->supplied_barrier, 102, 'supplied_barrier is correct';

        $args->{tick_size_barrier} = 0.000366;
        $c = produce_contract($args);
        is $c->low_barrier->supplied_barrier,  '99.9634',  'low supplied_barrier is correct';
        is $c->low_barrier->as_absolute,       '99.96',    'low barrier as_absolute is correct';
        is $c->high_barrier->supplied_barrier, '100.0366', 'high supplied_barrier is correct';
        is $c->high_barrier->as_absolute,      '100.04',   'high barrier as_absolute is correct';
        is $c->basis_spot,                     '100.00',   'basis_spot is correct';
    };

    subtest 'non-pricing_new & no entry_tick' => sub {
        $args->{date_pricing} = $now->epoch + 1;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([91, $now->epoch, $symbol]);
        $args->{tick_size_barrier} = 0.02;

        my $c = produce_contract($args);
        ok !$c->entry_tick,   'no entry_tick';
        ok !$c->pricing_new,  'is not pricing_new';
        ok !$c->low_barrier,  'no low_barrier';
        ok !$c->high_barrier, 'no high_barrier';
        ok !$c->basis_spot,   'no basis_spot';
    };

    subtest 'date_pricing equal to entry_tick' => sub {
        $args->{date_pricing} = $now->epoch + 1;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([91, $now->epoch, $symbol], [90, $now->epoch + 1, $symbol]);
        $args->{tick_size_barrier} = 0.02;

        my $c = produce_contract($args);
        is $c->current_spot,      '90.00',         'current_spot is 90.00';
        is $c->entry_tick->epoch, $now->epoch + 1, 'correct entry_tick';
        ok !$c->low_barrier,  'no low_barrier';
        ok !$c->high_barrier, 'no high_barrier';
        ok !$c->basis_spot,   'no basis_spot';
    };

    subtest 'date_pricing after entry_tick' => sub {
        $args->{date_pricing} = $now->epoch + 2;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [91, $now->epoch,     $symbol],
            [90, $now->epoch + 1, $symbol],
            [92, $now->epoch + 2, $symbol]);
        $args->{tick_size_barrier} = 0.02;

        my $c = produce_contract($args);
        is $c->current_spot,                   '92.00',         'current_spot is 92.00';
        is $c->entry_tick->epoch,              $now->epoch + 1, 'correct entry_tick';
        is $c->low_barrier->supplied_barrier,  '88.2',          'low supplied_barrier is correct';
        is $c->low_barrier->as_absolute,       '88.20',         'low barrier as_absolute is correct';
        is $c->high_barrier->supplied_barrier, '91.8',          'high supplied_barrier is correct';
        is $c->high_barrier->as_absolute,      '91.80',         'high barrier as_absolute is correct';
        is $c->basis_spot,                     '90',            'basis_spot is correct';
    };

    $args->{date_pricing} = $now;
};

subtest 'calculate_payout' => sub {
    my $expected = {
        0   => '0.99',
        1   => '1.00',
        2   => '1.01',
        11  => '1.10',
        12  => '1.12',
        97  => '2.60',
        116 => '3.14',
        219 => '8.75',
        243 => '11.11',
        300 => '19.59',
    };
    my $c = produce_contract($args);

    foreach my $tick_count (qw(0 1 2 11 12 97 116 219 243 300)) {
        is $c->calculate_payout($tick_count), $expected->{$tick_count}, "payout on tick $tick_count is " . $expected->{$tick_count};
    }
};

subtest 'minmum stake' => sub {
    $args->{amount} = 0.5;

    my $error = exception { produce_contract($args) };
    is $error->message_to_client->[0], 'Please enter a stake amount that\'s at least [_1].', 'message to client - Stake must be at least [_1] 1.';
    is $error->message_to_client->[1], '1.00';

    $args->{amount} = 0;
    $error = exception { produce_contract($args) };
    is $error->message_to_client->[0], 'Please enter a stake amount that\'s at least [_1].', 'message to client - Stake must be at least [_1] 1.';
    is $error->message_to_client->[1], '1.00';
};

subtest 'maximum stake' => sub {
    $args->{amount} = 1001;

    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'maximum stake limit', 'message - take profit too high';
    is $c->primary_validation_error->message_to_client->[0], 'Maximum stake allowed is [_1].',
        'message - Please enter a take profit amount that\'s higher than [_1].';
    is $c->primary_validation_error->message_to_client->[1], '1000.00';
};

subtest 'take_profit' => sub {
    $args->{amount} = 100;

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
        is $c->primary_validation_error->message_to_client->[1], '9900.00';
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
        is $c->target_payout,              '126.97';

        $args->{limit_order} = {
            take_profit => '50',
        };
        $c = produce_contract($args);
        is $c->take_profit->{amount},      '50';
        is $c->take_profit->{date}->epoch, $c->date_pricing->epoch;
        is $c->target_payout,              '150';
    };

    subtest 'non-pricing new' => sub {
        delete $args->{date_pricing};

        $args->{limit_order} = {
            take_profit => {
                amount => 5.11,
                date   => $now->epoch,
            }};
        $c = produce_contract($args);
        ok !$c->pricing_new, 'non pricing_new';
        is $c->take_profit->{amount},      '5.11';
        is $c->take_profit->{date}->epoch, $now->epoch;
        is $c->target_payout,              '105.11';

        delete $args->{limit_order};
    };
};

subtest 'tickcount_for' => sub {
    $args->{amount} = 100;
    my $c = produce_contract($args);

    is $c->tickcount_for(99.01),  0,   'the payout will be 99.01 at the start';
    is $c->tickcount_for(102.01), 3,   'the payout will reach 102 on tick 25';
    is $c->tickcount_for(150),    42,  'the payout will reach 150 on tick 42';
    is $c->tickcount_for(150.38), 42,  'the payout will reach 150 on tick 42';
    is $c->tickcount_for(105.11), 7,   'the payout will reach  105.11 on tick 7';
    is $c->tickcount_for(275.92), 103, 'the payout will reach  275.92 on tick 103';
};

subtest 'sell contract at entry tick' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, $symbol], [101, $now->epoch + 1, $symbol]);

    my $c = produce_contract($args);
    ok !$c->is_valid_to_sell, 'not valid to sell';

    is $c->primary_validation_error->message,           'wait for next tick after entry tick';
    is $c->primary_validation_error->message_to_client, 'Contract cannot be sold at entry tick. Please wait for the next tick.';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [101, $now->epoch + 1, $symbol],
        [101, $now->epoch + 2, $symbol]);

    $c = produce_contract($args);
    ok $c->is_valid_to_sell, 'valid to sell';
};

done_testing();

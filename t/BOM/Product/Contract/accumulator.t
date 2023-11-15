#!/etc/rmg/bin/perl

use strict;
use warnings;

use utf8;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Product::ContractFactory                qw(produce_contract);
use Finance::Contract::Longcode                  qw(shortcode_to_parameters);
use YAML::XS                                     qw(LoadFile);
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
    tick_size_barrier => 0.02,
};

subtest 'config' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, $symbol]);
    my $c = produce_contract($args);

    isa_ok $c, 'BOM::Product::Contract::Accu';
    is $c->code,          'ACCU',        'code ACCU';
    is $c->category_code, 'accumulator', 'category accumulator';
    ok $c->is_path_dependent, 'path dependent';
    is $c->tick_count,        300,   'tick count is 300';
    is $c->ticks_to_expiry,   300,   'ticks to expiry is 300';
    is $c->max_duration,      300,   'max duration is 300';
    is $c->ask_price,         1,     'ask_price is 1';
    is $c->growth_start_step, 1,     'growth_start_step is 1';
    is $c->max_payout,        10000, 'max_payout is 10000';
    ok !$c->pricing_engine,      'pricing_engine is undef';
    ok !$c->pricing_engine_name, 'pricing_engine_name is undef';
    ok !$c->payout,              'payout is not defined';
    ok !$c->take_profit,         'take_profit is not defined';
};

subtest 'growth rate validation' => sub {
    $args->{growth_rate} = undef;
    my $error = exception { produce_contract($args) };

    is $error->message_to_client->[0], 'Missing required contract parameters ([_1]).',
        'message to client - Missing required contract parameters ([_1]).';
    is $error->message_to_client->[1], 'growth_rate';

    $args->{growth_rate} = 0.09;

    $error = exception { produce_contract($args) };
    is $error->message_to_client->[0], 'Growth rate is not in acceptable range. Accepts [_1].',
        'message to client - Growth rate is not in acceptable range. Accepts [_1].';
    is $error->message_to_client->[1], '0.01, 0.02, 0.03, 0.04, 0.05';

    $args->{growth_rate} = 0.01;
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
        [
            'After the entry spot tick, your stake will grow continuously by [_1]% for every tick that the spot price remains within the ± [_2] % from the previous spot price.',
            [1],
            [2]
        ],
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

subtest 'barrier pip size' => sub {
    my $c = produce_contract($args);
    is $c->barrier_pip_size, $c->underlying->pip_size / 10, 'correct barrier pip size';
};

subtest 'barrier' => sub {
    subtest 'rounded barriers' => sub {
        $args->{date_pricing} = $now->epoch + 1;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([91, $now->epoch, $symbol]);
        my $c = produce_contract($args);

        subtest 'high_barrier' => sub {
            my %examples = (
                '1.23'               => '1.230',
                '4583'               => '4583.000',
                '56.4870000000001'   => '56.488',
                '987.00000000000009' => '987.001',
                '35.000000000'       => '35.000'
            );
            ok !$c->display_high_barrier, 'no display_high_barrier';

            while (my ($raw_barrier, $display_barrier) = each %examples) {
                is $c->round_high_barrier($raw_barrier), $display_barrier, 'correct display high barrier';
            }
        };

        subtest 'low_barrier' => sub {
            my %examples = (
                '1.23'               => '1.230',
                '4583'               => '4583.000',
                '56.4870000000001'   => '56.487',
                '987.00000000000009' => '987.000',
                '35.5278'            => '35.527'
            );
            ok !$c->display_low_barrier, 'no display_low_barrier';

            while (my ($raw_barrier, $display_barrier) = each %examples) {
                is $c->round_low_barrier($raw_barrier), $display_barrier, 'correct display low barrier';
            }
        };
    };

    subtest 'pricing_new' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, $symbol], [101, $now->epoch + 1, $symbol]);
        $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        is $c->low_barrier,  undef, 'low barrier is not defined';
        is $c->high_barrier, undef, 'high barrier is not defined';
    };

    subtest 'non-pricing_new & no entry_tick' => sub {
        $args->{date_pricing} = $now->epoch + 1;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([91, $now->epoch, $symbol]);

        my $c = produce_contract($args);
        ok !$c->entry_tick, 'no entry_tick';
        is $c->tick_count_after_entry, 0, 'no tick after entry_tick';
        ok !$c->pricing_new,          'is not pricing_new';
        ok !$c->low_barrier,          'no low_barrier';
        ok !$c->high_barrier,         'no high_barrier';
        ok !$c->display_low_barrier,  'no display_low_barrier';
        ok !$c->display_high_barrier, 'no display_high_barrier';
        ok !$c->basis_spot,           'no basis_spot';
    };

    subtest 'date_pricing equal to entry_tick' => sub {
        $args->{date_pricing} = $now->epoch + 1;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([91, $now->epoch, $symbol], [90, $now->epoch + 1, $symbol]);

        my $c = produce_contract($args);
        is $c->current_spot,      '90.00',         'current_spot is 90.00';
        is $c->entry_tick->epoch, $now->epoch + 1, 'correct entry_tick';
        ok !$c->low_barrier,          'no low_barrier';
        ok !$c->high_barrier,         'no high_barrier';
        ok !$c->display_low_barrier,  'no display_low_barrier';
        ok !$c->display_high_barrier, 'no display_high_barrier';
        ok !$c->basis_spot,           'no basis_spot';
        is $c->current_spot_high_barrier, '91.800', 'current_spot_high_barrier is correct';
        is $c->current_spot_low_barrier,  '88.200', 'current_spot_low_barrier is correct';
        is $c->barrier_spot_distance,     '1.800',  'barrier_spot_distance is correct';
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
        is $c->tick_count_after_entry,         1,               'recieved one tick after entry_tick';
        is $c->low_barrier->supplied_barrier,  '88.2',          'low supplied_barrier is correct';
        is $c->low_barrier->as_absolute,       '88.20',         'low barrier as_absolute is correct';
        is $c->display_low_barrier,            '88.200',        'display_low_barrier is correct';
        is $c->current_spot_low_barrier,       '90.160',        'current_spot_low_barrier is correct';
        is $c->high_barrier->supplied_barrier, '91.8',          'high supplied_barrier is correct';
        is $c->high_barrier->as_absolute,      '91.80',         'high barrier as_absolute is correct';
        is $c->display_high_barrier,           '91.800',        'display_high_barrier is correct';
        is $c->current_spot_high_barrier,      '93.840',        'current_spot_high_barrier is correct';
        is $c->barrier_spot_distance,          '1.840',         'barrier_spot_distance is correct';
        is $c->basis_spot,                     '90',            'basis_spot is correct';
    };

    subtest 'no tick recieved for date_pricing' => sub {
        $args->{date_pricing} = $now->epoch + 3;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [89, $now->epoch,     $symbol],
            [90, $now->epoch + 1, $symbol],
            [91, $now->epoch + 2, $symbol]);
        $args->{tick_size_barrier} = 0.02;
        my $c = produce_contract($args);

        is $c->current_spot,                   '91.00',         'current_spot is 92.00';
        is $c->entry_tick->epoch,              $now->epoch + 1, 'correct entry_tick';
        is $c->tick_count_after_entry,         1,               'recieved one tick after entry_tick';
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
    $args->{amount}    = 1000;
    $args->{max_stake} = 500;

    my $error = exception { produce_contract($args) };
    is $error->message_to_client->[0], 'Maximum stake allowed is [_1].', 'maximum stake limit';
    is $error->message_to_client->[1], '500.00';

    delete $args->{max_stake};
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
                order_amount => 5.11,
                order_date   => $now->epoch,
            }};
        $c = produce_contract($args);
        ok !$c->pricing_new, 'non pricing_new';
        is $c->take_profit->{amount},      '5.11';
        is $c->take_profit->{date}->epoch, $now->epoch;
        is $c->target_payout,              '105.11';

        delete $args->{limit_order};
    };
};

subtest 'ticks_for_payout' => sub {
    $args->{amount} = 100;
    my $c = produce_contract($args);

    dies_ok { $c->ticks_for_payout(99.99, 1) } 'the payout will exceed 100 at the start';
    is $c->ticks_for_payout(100.00),    1, 'the payout will reach 100 on tick 1';
    is $c->ticks_for_payout(100.00, 1), 1, 'the payout will not exceed 100 on tick 1';
    is $c->ticks_for_payout(102.01),    3, 'the payout will reach 102 on tick 25';
    my $p7 = $c->calculate_payout(7);
    my $p8 = $c->calculate_payout(8);
    is $c->ticks_for_payout(0.5 * ($p7 + $p8)),    8, 'got ceiled tick count';
    is $c->ticks_for_payout(0.5 * ($p7 + $p8), 1), 7, 'got floored tick count';
    is $c->ticks_for_payout($p8),                  8, 'exact ceiled tick count as expected';
    is $c->ticks_for_payout($p8, 1),               8, 'exact floored tick count as expected';
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

subtest 'sell contract with current price less than stake' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [101, $now->epoch + 1, $symbol],
        [101, $now->epoch + 2, $symbol]);

    $args->{growth_start_step} = 2;

    my $c = produce_contract($args);
    ok !$c->is_valid_to_sell, 'not valid to sell';

    is $c->primary_validation_error->message,           'sell price should be more than stake';
    is $c->primary_validation_error->message_to_client, 'Contract cannot be sold at this time. Please try again.';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [101, $now->epoch + 1, $symbol],
        [101, $now->epoch + 2, $symbol],
        [101, $now->epoch + 3, $symbol]);

    $c = produce_contract($args);
    ok $c->is_valid_to_sell, 'valid to sell';

    $args->{growth_start_step} = 1;
};

subtest 'tick_stream' => sub {

    my @ticks = map { [100, $now->epoch + $_, $symbol] } (-20 .. 0);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@ticks);

    $args->{date_start}   = $now->epoch - 20;
    $args->{date_pricing} = $now;

    my $c = produce_contract($args);

    is scalar @{$c->tick_stream},    10,              'at most 10 numbers are in tick_stream';
    is $c->tick_stream->[-1]{epoch}, $now->epoch,     'last tick is correct';
    is $c->tick_stream->[0]{epoch},  $now->epoch - 9, 'first tick is correct';

    @ticks = map { [100, $now->epoch + $_, $symbol] } (-5 .. 0);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@ticks);

    $args->{date_start} = $now->epoch - 5;

    $c = produce_contract($args);
    is $c->tick_stream->[0]{epoch}, $c->entry_tick->{epoch}, 'first tick is the entry_tick';

    $args->{date_start} = $now->epoch;
};

subtest 'sell_commission' => sub {

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [101, $now->epoch + 1, $symbol],
        [101, $now->epoch + 2, $symbol],
        [101, $now->epoch + 3, $symbol]);

    $args->{date_pricing} = $now->epoch + 3;
    my $c = produce_contract($args);

    is $c->tick_count_after_entry, 2,                  'tick_count_after_entry is correct';
    is $c->sell_commission,        0.0199989999999928, 'sell_commission is correct';

    $args->{date_pricing} = $now;
};

subtest 'tick size barrier values' => sub {
    #making sure that tick_size_barrier values don't get changed accidentally
    my $config   = LoadFile('/home/git/regentmarkets/bom-config/share/default_tick_size_barrier_accumulator.yml');
    my $expected = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Contract/expected_tick_size_barrier_accumulator.yml');
    cmp_deeply($config, $expected);
};

done_testing();

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
    is $c->buy_commission, 0.529763542771197, 'correct buy commission';

    $args->{date_pricing} = $now->plus_time_interval('1s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.03766', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price,       '1.39',            'has bid price';
    is $c->sell_commission, 0.530466689262102, 'correct sell commission';

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
    my $shortcode = 'TURBOSSHORT_1HZ25V_20.00_' . $now->epoch . '_' . $now->plus_time_interval('5m')->epoch . '_351610000000_0.0376600318';

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
};

subtest 'longcode' => sub {
    my $c = produce_contract($args);
    is_deeply(
        $c->longcode,
        [
            'Your payout will be [_5] for each point below [_4] at expiry time',
            ['Volatility 25 (1s) Index'],
            ['contract start time'],
            {
                class => 'Time::Duration::Concise::Localize',
                value => 300
            },
            '351610.00',
            '0.0376600318'
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

done_testing();

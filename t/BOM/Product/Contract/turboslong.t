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
    barrier      => '1690.00',
};

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

    my $barriers = $c->strike_price_choices;
    is $barriers->[0],                               '-5.44',    'correct first barrier';
    is $barriers->[5],                               '-20.75',   'correct 5th barrier';
    is $barriers->[-1],                              '-881.51',  'correct last barrier';
    is sprintf("%.5f", $c->bid_probability->amount), '72.60042', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '73.39958', 'correct ask probability';
};

subtest 'number of contracts' => sub {
    # number of contracts = stake / options ask price
    # must be the same
    my $c = produce_contract($args);
    ok $c->pricing_new, 'this is a new contract';
    cmp_ok sprintf("%.10f", $c->number_of_contracts), '==', '1.3624055686', 'correct number of contracts';
    ok !$c->is_expired, 'not expired (obviously but just be safe)';

    $args->{date_pricing} = $now->plus_time_interval('1s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '1.36241', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '122.07', 'has bid price';

    $args->{date_pricing} = $now->plus_time_interval('2s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '1.36241', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '364.52', 'has bid price, and higher because spot is higher now';

    $args->{date_pricing} = $now->plus_time_interval('3s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '1.36241', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok $c->is_expired,   'expired';
    is $c->bid_price, '0.00', 'does not have bid price';
};

subtest 'expired and not breached barrier' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [1763.00, $epoch,       $symbol],
        [1780.00, $epoch + 60,  $symbol],
        [1950.00, $epoch + 119, $symbol],
        [1958.00, $epoch + 120, $symbol],
        [1390.00, $epoch + 121, $symbol],
    );

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
    my $shortcode = 'TURBOSLONG_R_100_100.00_' . $now->epoch . '_' . $now->plus_time_interval('2m')->epoch . '_1690000000_1.3624055686';

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
            'Your payout will be [_5] for each point above [_4] at expiry time',
            ['Volatility 100 Index'],
            ['contract start time'],
            {
                class => 'Time::Duration::Concise::Localize',
                value => 120,
            },
            '1690.00',
            '1.3624055686'
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
        cmp_ok $c->barrier->as_absolute,                 'eq', '1690.00', 'correct absolute barrier (it will be pipsized) ';
        cmp_ok $c->entry_tick->quote,                    'eq', '1763',    'correct entry tick';
        cmp_ok $c->current_spot,                         'eq', '1763.00', 'correct current spot (it will be pipsized)';
        cmp_ok sprintf("%.2f", $c->number_of_contracts), 'eq', '1.36',    'number of contracts are correct';

        $args->{date_pricing} = $now->plus_time_interval('2m');
        $c = produce_contract($args);
        ok $c->bid_price, 'ok bid price';
        cmp_ok sprintf("%.2f", $c->number_of_contracts),  'eq', '1.36',    'number of contracts are correct';
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

done_testing();

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
    [68258.19, $epoch,       $symbol],
    [68261.32, $epoch + 1,   $symbol],
    [68259.29, $epoch + 2,   $symbol],
    [68258.97, $epoch + 3,   $symbol],
    [69126.23, $epoch + 120, $symbol],
    [69176.23, $epoch + 180, $symbol],
    [69418.19, $epoch + 599, $symbol],
    [69420.69, $epoch + 600, $symbol],
    [69419.48, $epoch + 601, $symbol],
);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $args = {
    bet_type     => 'TURBOSCALL',
    underlying   => $symbol,
    date_start   => $now,
    date_pricing => $now,
    duration     => '10h',
    currency     => 'USD',
    amount_type  => 'stake',
    amount       => 10,
    barrier      => '68200.00',
};

subtest 'config' => sub {
    my $c = eval { produce_contract($args); };

    isa_ok $c, 'BOM::Product::Contract::Turboscall';
    is $c->code,          'TURBOSCALL', 'code TURBOSCALL';
    is $c->pricing_code,  'TURBOSCALL', 'pricing code TURBOSCALL';
    is $c->category_code, 'turbos',     'category turbos';
    ok !$c->is_path_dependent,      'is not path dependent';
    ok !defined $c->pricing_engine, 'price engine is udefined';
    ok $c->is_intraday,             'is intraday';
    isa_ok $c->barrier, 'BOM::Product::Contract::Strike';
    cmp_ok $c->barrier->as_absolute, '==', 68200, 'correct absolute barrier';
    is $c->ask_price, 10, 'ask_price is 10';
    ok $c->pricing_new, 'this is a new contract';

    is sprintf("%.5f", $c->bid_probability->amount), '46.03510', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '70.34490', 'correct ask probability';
};

subtest 'number of contracts' => sub {
    # number of contracts = stake / options ask price
    # must be the same
    my $c = produce_contract($args);
    ok $c->pricing_new, 'this is a new contract';
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.14216', 'correct number of contracts';
    ok !$c->is_expired, 'not expired (obviously but just be safe)';

    $args->{date_pricing} = $now->plus_time_interval('2s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.14216', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '8.43', 'has bid price';

    $args->{date_pricing} = $now->plus_time_interval('3m');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.14216', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '138.78', 'has bid price, and higher because spot is higher now';

    $args->{date_pricing} = $now->plus_time_interval('12h');
    $c = produce_contract($args);
    ok $c->is_expired, 'contract is expired, this is a 10h contract';
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.14216', 'correct number of contracts';
};

subtest 'shortcode' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s')->epoch;
    my $c         = produce_contract($args);
    my $shortcode = 'TURBOSCALL_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_68200000000_0.14216';

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
                value => 36000
            },
            '68200.00',
            '0.14216'
        ],
        'longcode matches'
    );
};

subtest 'entry and exit tick' => sub {
    lives_ok {
        $args->{duration}     = '10m';
        $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Turboscall';
        is $c->code, 'TURBOSCALL';
        ok $c->is_intraday,             'is intraday';
        ok !defined $c->pricing_engine, 'price engine is udefined';
        cmp_ok $c->barrier->as_absolute,                 'eq', '68200.00', 'correct absolute barrier (it will be pipsized) ';
        cmp_ok $c->entry_tick->quote,                    'eq', '68258.19', 'correct entry tick';
        cmp_ok $c->current_spot,                         'eq', '68258.19', 'correct current spot (it will be pipsized)';
        cmp_ok sprintf("%.2f", $c->number_of_contracts), 'eq', '0.14',     'number of contracts are correct';

        $args->{date_pricing} = $now->plus_time_interval('10m');
        $c = produce_contract($args);
        ok $c->bid_price, 'ok bid price';
        cmp_ok sprintf("%.2f", $c->number_of_contracts),  'eq', '0.14',     'number of contracts are correct';
        cmp_ok sprintf("%.2f", $c->current_spot),         'eq', '69420.69', 'correct spot price';
        cmp_ok sprintf("%.2f", $c->barrier->as_absolute), 'eq', '68200.00', 'correct strike';

        ok $c->is_expired, 'expired';
        cmp_ok sprintf("%.2f", $c->value), 'eq', '173.53', '(strike - spot) * number of contracts';
        ok $c->exit_tick,                                   'has exit tick';
        ok $c->exit_tick->quote > $c->barrier->as_absolute, 'exit tick is bigger than strike price';
        ok $c->value > 0,                                   'contract value is bigger than 0, exit tick is bigger than strike price';
        cmp_ok sprintf("%.2f", $c->value), 'eq', '173.53',   'correct payout';
        cmp_ok $c->exit_tick->quote,       'eq', '69420.69', 'correct exit tick';
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

done_testing();

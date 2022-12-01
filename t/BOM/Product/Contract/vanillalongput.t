#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 7;
use Test::Warnings;
use Test::Exception;
use Test::Deep;
use Date::Utility;
use Format::Util::Numbers qw/roundcommon/;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory                qw(produce_contract);
use BOM::Config::Runtime;

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [68258.19, $now->epoch,       'R_100'],
    [68261.32, $now->epoch + 1,   'R_100'],
    [68259.29, $now->epoch + 2,   'R_100'],
    [68258.97, $now->epoch + 3,   'R_100'],
    [69126.23, $now->epoch + 120, 'R_100'],
    [69176.23, $now->epoch + 180, 'R_100'],
    [69418.19, $now->epoch + 599, 'R_100'],
    [69420.69, $now->epoch + 600, 'R_100'],
    [69419.48, $now->epoch + 601, 'R_100']);

my $args = {
    bet_type     => 'Vanillalongput',
    underlying   => 'R_100',
    date_start   => $now,
    date_pricing => $now,
    duration     => '10h',
    currency     => 'USD',
    amount_type  => 'stake',
    amount       => 10,
    barrier      => '69420',
};

subtest 'basic produce_contract' => sub {

    my $c = produce_contract($args);
    isa_ok $c, 'BOM::Product::Contract::Vanillalongput';
    is $c->code,         'VANILLALONGPUT';
    is $c->pricing_code, 'VANILLA_PUT';
    ok $c->is_intraday,        'is intraday';
    ok !$c->is_path_dependent, 'is not path dependent';
    isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::BlackScholes';
    isa_ok $c->barrier,        'BOM::Product::Contract::Strike';
    cmp_ok $c->barrier->as_absolute, '==', 69420, 'correct absolute barrier';
    ok $c->pricing_new, 'is pricing new';
};

subtest 'number of contracts' => sub {
    # number of contracts = stake / options ask price
    # must be the same
    my $c = produce_contract($args);
    ok $c->pricing_new, 'contract is new';
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.00608', 'correct number of contracts';
    ok !$c->is_expired, 'not expired';

    $args->{date_pricing} = $now->plus_time_interval('2s');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.00608', 'correct number of contracts';

    $args->{date_pricing} = $now->plus_time_interval('12h');
    $c = produce_contract($args);
    cmp_ok sprintf("%.5f", $c->number_of_contracts), '==', '0.00608', 'correct number of contracts';
};

subtest 'shortcode' => sub {

    my $c         = produce_contract($args);
    my $shortcode = 'VANILLALONGPUT_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_69420000000_0.00608';

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
};

subtest 'longcode' => sub {
    my $c = produce_contract($args);
    is_deeply(
        $c->longcode,
        [
            'Your payout will be [_5] for each point below [_4] at expiry time',
            ['Volatility 100 Index'],
            ['contract start time'],
            {
                class => 'Time::Duration::Concise::Localize',
                value => 36000
            },
            '69420.00',
            '0.00608'
        ],
        'longcode matches'
    );
};

subtest 'entry and exit tick' => sub {
    lives_ok {
        $args->{duration}     = '10m';
        $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Vanillalongput';
        is $c->code, 'VANILLALONGPUT';
        ok $c->is_intraday, 'is intraday';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::BlackScholes';
        cmp_ok $c->barrier->as_absolute,                 'eq', '69420.00', 'correct absolute barrier (it will be pipsized) ';
        cmp_ok $c->entry_tick->quote,                    'eq', '68258.19', 'correct entry tick';
        cmp_ok $c->current_spot,                         'eq', '68258.19', 'correct current spot (it will be pipsized)';
        cmp_ok sprintf("%.5f", $c->number_of_contracts), 'eq', '0.00860',  'number of contrats are correct';

        $args->{date_pricing} = $now->plus_time_interval('10m');
        $c = produce_contract($args);
        ok $c->is_expired,                                  'expired';
        ok $c->exit_tick,                                   'has exit tick';
        ok $c->exit_tick->quote > $c->barrier->as_absolute, 'exit tick is bigger than strike price';
        ok $c->value == 0,                                  'contract is worthless';
        cmp_ok $c->exit_tick->quote, 'eq', '69420.69', 'correct exit tick';

    }
    'winning the contract';

    lives_ok {
        my $c = produce_contract($args);

        $args->{duration}     = '20m';
        $args->{date_pricing} = $now->plus_time_interval('20m');
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 1199,
            quote      => 69327.58,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 1201,
            quote      => 69330.39,
        });
        $c = produce_contract($args);
        ok $c->is_expired,                                  'expired';
        ok $c->exit_tick,                                   'has exit tick';
        ok $c->exit_tick->quote < $c->barrier->as_absolute, 'exit tick is smaller than strike price';
        ok $c->value > 0,                                   'contract worth something';
        cmp_ok sprintf("%.5f", $c->number_of_contracts), 'eq', '0.00860',  'number of contrats are correct';
        cmp_ok $c->current_spot,                         'eq', '69327.58', 'correct ask probability';
        cmp_ok $c->barrier->as_absolute,                 'eq', '69420.00', 'correct strike';

        ok $c->is_expired, 'expired';
        cmp_ok sprintf("%.2f", $c->value), 'eq', '0.79',     '(exit quote - strike) * number of contracts';
        cmp_ok $c->exit_tick->quote,       'eq', '69327.58', 'correct exit tick';
    }
    'losing the contract';
};

subtest 'pricing an expired option' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch + 3600,
        quote      => 0.99,
    });

    lives_ok {
        $args->{duration}     = '10m';
        $args->{date_pricing} = $now->plus_time_interval('10m');
        my $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        my $contract_value = $c->value;

        $args->{date_pricing} = $now->plus_time_interval('1h');
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        is $c->value,     $contract_value, 'contract value is same regardless when we price it';
        is $c->bid_price, $contract_value, 'contract price is same regardless when we price it';
    }
    'losing the contract';

};

done_testing;

#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 15;
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
my $now = Date::Utility->new('10-03-2015');

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
    bet_type     => 'Vanillalongcall',
    underlying   => 'R_100',
    date_start   => $now,
    date_pricing => $now,
    duration     => '10h',
    currency     => 'USD',
    amount_type  => 'stake',
    amount       => 10,
    barrier      => '69420.00',
};

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my $per_symbol_config = {
    'vol_markup'              => 0.025,
    'bs_markup'               => 0,
    'min_number_of_contracts' => {'USD' => 0},
    'max_number_of_contracts' => {'USD' => 1000},
    'delta_config'            => [0.1, 0.3, 0.5, 0.7, 0.9],
    'max_strike_price_choice' => 10,
    'risk_profile'            => 'low_risk',
    'spread_spot'             => 0
};
$per_symbol_config = JSON::MaybeXS::encode_json($per_symbol_config);
$app_config->set({'quants.vanilla.per_symbol_config.R_100_intraday' => $per_symbol_config});

my $risk_profile_config = {'USD' => 20};
$risk_profile_config = JSON::MaybeXS::encode_json($risk_profile_config);

$app_config->set({'quants.vanilla.risk_profile.low_risk' => $risk_profile_config});

subtest 'basic produce_contract' => sub {

    my $c = produce_contract($args);
    isa_ok $c, 'BOM::Product::Contract::Vanillalongcall';
    is $c->code,         'VANILLALONGCALL';
    is $c->pricing_code, 'VANILLA_CALL';
    ok $c->is_intraday,        'is intraday';
    ok !$c->is_path_dependent, 'is not path dependent';
    isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::BlackScholes';
    isa_ok $c->barrier,        'BOM::Product::Contract::Strike';
    cmp_ok $c->barrier->as_absolute, '==', 69420, 'correct absolute barrier';
    ok $c->pricing_new, 'this is a new contract';

    # Refer Vanillalongcall.pm for the formula
    is sprintf("%.5f", $c->bid_probability->amount), '439.92626', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '480.86832', 'correct ask probability';
};

subtest 'number of contracts' => sub {
    # number of contracts = stake / options ask price
    # must be the same
    my $c = produce_contract($args);
    ok $c->pricing_new, 'this is a new contract';
    cmp_ok $c->number_of_contracts, '==', '0.0207957139', 'correct number of contracts';
    ok !$c->is_expired, 'not expired (obviously but just be safe)';

    $args->{date_pricing} = $now->plus_time_interval('2s');
    $c = produce_contract($args);
    cmp_ok $c->number_of_contracts, '==', '0.0207957139', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '9.16', 'has bid price';

    $args->{date_pricing} = $now->plus_time_interval('3m');
    $c = produce_contract($args);
    cmp_ok $c->number_of_contracts, '==', '0.0207957139', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '16.46', 'has bid price, and higher because spot is higher now';

    $args->{date_pricing} = $now->plus_time_interval('12h');
    $c = produce_contract($args);
    ok $c->is_expired, 'contract is expired, this is a 10h contract';
    cmp_ok $c->number_of_contracts, '==', '0.0207957139', 'correct number of contracts';
};

subtest 'shortcode' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s')->epoch;
    my $c         = produce_contract($args);
    my $shortcode = 'VANILLALONGCALL_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_69420000000_0.0207957139';

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

subtest 'shortcode S1P' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s')->epoch;
    my $c         = produce_contract($args);
    my $shortcode = 'VANILLALONGCALL_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_S116181P_0.0207957139';

    # 68258.19 + 1161.81 = 69420

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
            'Your payout will be [_5] for each point above [_4] at expiry time',
            ['Volatility 100 Index'],
            ['contract start time'],
            {
                class => 'Time::Duration::Concise::Localize',
                value => 36000
            },
            '69420.00',
            '0.0207957139'
        ],
        'longcode matches'
    );
};

subtest 'entry and exit tick' => sub {
    lives_ok {
        $args->{duration}     = '10m';
        $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Vanillalongcall';
        is $c->code, 'VANILLALONGCALL';
        ok $c->is_intraday, 'is intraday';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::BlackScholes';
        cmp_ok $c->barrier->as_absolute,                 'eq', '69420.00', 'correct absolute barrier (it will be pipsized) ';
        cmp_ok $c->entry_tick->quote,                    'eq', '68258.19', 'correct entry tick';
        cmp_ok $c->current_spot,                         'eq', '68258.19', 'correct current spot (it will be pipsized)';
        cmp_ok sprintf("%.2f", $c->number_of_contracts), 'eq', '1716.53',  'number of contracts are correct';

        $args->{date_pricing} = $now->plus_time_interval('10m');
        $c = produce_contract($args);
        ok $c->bid_price, 'ok bid price';
        cmp_ok sprintf("%.2f", $c->number_of_contracts),  'eq', '1716.53',  'number of contracts are correct';
        cmp_ok sprintf("%.2f", $c->current_spot),         'eq', '69420.69', 'correct spot price';
        cmp_ok sprintf("%.2f", $c->barrier->as_absolute), 'eq', '69420.00', 'correct strike';

        ok $c->is_expired, 'expired';
        cmp_ok sprintf("%.2f", $c->value), 'eq', '1184.41', '(strike - spot) * number of contracts';
        ok $c->exit_tick,                                   'has exit tick';
        ok $c->exit_tick->quote > $c->barrier->as_absolute, 'exit tick is bigger than strike price';
        ok $c->value > 0,                                   'contract value is bigger than 0, exit tick is bigger than strike price';
        cmp_ok sprintf("%.2f", $c->value), 'eq', '1184.41',  'correct payout';
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
        ok $c->value == 0,                                  'contract is worthless, exit tick is smaller than strike price';
        cmp_ok $c->exit_tick->quote, 'eq', '69327.58', 'correct exit tick';
    }
    'losing the contract';
};

subtest 'pricing an expired option' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch + 3600,
        quote      => 99999.99,
    });

    lives_ok {
        $args->{duration}     = '10m';
        $args->{date_pricing} = $now->plus_time_interval('10m');
        my $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        my $contract_value = $c->value;

        $args->{duration}     = '10m';
        $args->{date_pricing} = $now->plus_time_interval('1h');
        $c                    = produce_contract($args);
        ok $c->is_expired, 'expired';
        is $c->value,     $contract_value, 'contract value is same regardless when we price it';
        is $c->bid_price, $contract_value, 'contract price is same regardless when we price it';
    }
    'winning the contract';

};

subtest 'risk management tools' => sub {
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    lives_ok {
        my $c                   = produce_contract($args);
        my $number_of_contracts = $c->number_of_contracts;

        $per_symbol_config               = JSON::MaybeXS::decode_json($per_symbol_config);
        $per_symbol_config->{vol_markup} = 0.05;
        $per_symbol_config               = JSON::MaybeXS::encode_json($per_symbol_config);
        $app_config->set({'quants.vanilla.per_symbol_config.R_100_intraday' => $per_symbol_config});

        $c = produce_contract($args);
        my $number_of_contracts_with_markup = $c->number_of_contracts;

        ok $number_of_contracts > $number_of_contracts_with_markup, 'contract became more expensive with markup';
    }
    'vol markup tool works';

    lives_ok {
        my $c                   = produce_contract($args);
        my $number_of_contracts = $c->number_of_contracts;

        $per_symbol_config               = JSON::MaybeXS::decode_json($per_symbol_config);
        $per_symbol_config->{vol_markup} = 0.025;
        $per_symbol_config->{bs_markup}  = 0.1;
        $per_symbol_config               = JSON::MaybeXS::encode_json($per_symbol_config);
        $app_config->set({'quants.vanilla.per_symbol_config.R_100_intraday' => $per_symbol_config});

        $c = produce_contract($args);
        my $number_of_contracts_with_markup = $c->number_of_contracts;

        ok $number_of_contracts > $number_of_contracts_with_markup, 'contract became more expensive with markup';
    }
    'black scholes markup works';

    lives_ok {
        $args->{date_start}   = $now;
        $args->{date_pricing} = $now;
        $args->{barrier}      = '+0.60';
        $args->{stake}        = '1000';

        $per_symbol_config                            = JSON::MaybeXS::decode_json($per_symbol_config);
        $per_symbol_config->{min_number_of_contracts} = {'USD' => 0};
        $per_symbol_config->{max_number_of_contracts} = {'USD' => 2};
        $per_symbol_config                            = JSON::MaybeXS::encode_json($per_symbol_config);
        $app_config->set({'quants.vanilla.per_symbol_config.R_100_intraday' => $per_symbol_config});
        my $c = produce_contract($args);

        ok !$c->is_valid_to_buy, 'invalid to buy';
        is $c->primary_validation_error->message,                'maximum stake limit',            'correct error message';
        is $c->primary_validation_error->message_to_client->[0], 'Maximum stake allowed is [_1].', 'correct message to client';
    }
    'number of contracts validation';
};

subtest 'strike price choices intraday' => sub {
    $args->{duration} = '10h';
    my $c = produce_contract($args);

    my @expected_strike_price_choices = ('+3061.20', '+1259.80', '+39.00', '-1160.50', '-2855.20');
    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');
};

subtest 'strike price choices >intraday' => sub {

    $per_symbol_config                            = JSON::MaybeXS::decode_json($per_symbol_config);
    $per_symbol_config->{min_number_of_contracts} = {'USD' => 0};
    $per_symbol_config->{max_number_of_contracts} = {'USD' => 1000};
    $per_symbol_config->{bs_markup}               = 0;
    $per_symbol_config                            = JSON::MaybeXS::encode_json($per_symbol_config);
    $app_config->set({'quants.vanilla.per_symbol_config.R_100_daily' => $per_symbol_config});

    $args->{duration} = '25h';
    my $c = produce_contract($args);

    my @expected_strike_price_choices =
        ('64000.00', '65000.00', '66000.00', '67000.00', '68000.00', '69000.00', '70000.00', '71000.00', '72000.00', '73000.00');

    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');
};

subtest 'strike price choices ultra long duration' => sub {

    $per_symbol_config                            = JSON::MaybeXS::decode_json($per_symbol_config);
    $per_symbol_config->{min_number_of_contracts} = {'USD' => 0};
    $per_symbol_config->{max_number_of_contracts} = {'USD' => 1000};
    $per_symbol_config->{bs_markup}               = 0;
    $per_symbol_config                            = JSON::MaybeXS::encode_json($per_symbol_config);
    $app_config->set({'quants.vanilla.per_symbol_config.R_100_daily' => $per_symbol_config});

    $args->{duration} = '69d';
    my $c = produce_contract($args);

    my @expected_strike_price_choices =
        ('43000.00', '52000.00', '61000.00', '70000.00', '79000.00', '88000.00', '97000.00', '106000.00', '115000.00', '124000.00');

    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');
};

subtest 'strike price choice validation' => sub {
    $args->{duration} = '10h';
    my $c = produce_contract($args);

    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'InvalidBarrier', 'correct error message';
    is $c->primary_validation_error->message_to_client->[0], 'Barriers available are +3061.20, +1259.80, +39.00, -1160.50, -2855.20',
        'correct error message to client';

    $args->{duration} = '10h';
    $args->{barrier}  = '+39.00';
    $args->{stake}    = '10';
    $c                = produce_contract($args);

    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'risk profile max stake per trade validation' => sub {

    $app_config->set({'quants.vanilla.per_symbol_config.R_100_intraday' => $per_symbol_config});

    my $risk_profile_config = {'USD' => 20};
    $risk_profile_config = JSON::MaybeXS::encode_json($risk_profile_config);

    $app_config->set({'quants.vanilla.risk_profile.extreme_risk' => $risk_profile_config});

    $args->{stake}    = 200;
    $args->{duration} = '10h';
    $args->{barrier}  = '+39.00';
    my $c = produce_contract($args);

    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message,                'maximum stake limit',            'correct error message';
    is $c->primary_validation_error->message_to_client->[0], 'Maximum stake allowed is [_1].', 'correct error message to client';

    $args->{stake}    = 10;
    $args->{duration} = '10h';
    $args->{barrier}  = '+39.00';
    $c                = produce_contract($args);

    ok $c->is_valid_to_buy, 'valid to buy now';
};

subtest 'check if spread is applied properly' => sub {

    my $c   = produce_contract($args);
    my $bid = $c->bid_probability->amount;
    my $ask = $c->ask_probability->amount;

    $per_symbol_config                = JSON::MaybeXS::decode_json($per_symbol_config);
    $per_symbol_config->{spread_spot} = 0.1;
    $per_symbol_config                = JSON::MaybeXS::encode_json($per_symbol_config);
    $app_config->set({'quants.vanilla.per_symbol_config.R_100_intraday' => $per_symbol_config});

    $c = produce_contract($args);

    ok $c->bid_probability->amount < $bid, 'spread applied properly';
    ok $c->ask_probability->amount > $ask, 'spread applied properly';

};

done_testing;

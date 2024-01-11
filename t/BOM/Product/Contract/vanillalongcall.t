#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 22;
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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [68258.19, $now->epoch,       'R_100'],
    [68261.32, $now->epoch + 1,   'R_100'],
    [68259.29, $now->epoch + 2,   'R_100'],
    [68258.97, $now->epoch + 3,   'R_100'],
    [69126.23, $now->epoch + 120, 'R_100'],
    [69176.23, $now->epoch + 180, 'R_100'],
    [69418.19, $now->epoch + 599, 'R_100'],
    [69420.69, $now->epoch + 600, 'R_100'],
    [69420.69, $now->epoch + 601, 'R_100']);

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

subtest 'barrier too far' => sub {
    local $args->{barrier} = '1240000.00';
    my $c = produce_contract($args);
    throws_ok { $c->number_of_contracts } "BOM::Product::Exception", "too big barrier throws valid exception";
};

subtest 'number of contracts' => sub {
    # number of contracts = stake / options ask price
    # must be the same
    my $c = produce_contract($args);
    ok $c->pricing_new, 'this is a new contract';
    cmp_ok $c->number_of_contracts, '==', '0.02080', 'correct number of contracts';
    ok !$c->is_expired, 'not expired (obviously but just be safe)';

    $args->{date_pricing} = $now->plus_time_interval('2s');
    $c = produce_contract($args);
    cmp_ok $c->number_of_contracts, '==', '0.02080', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '9.16', 'has bid price';

    $args->{date_pricing} = $now->plus_time_interval('3m');
    $c = produce_contract($args);
    cmp_ok $c->number_of_contracts, '==', '0.02080', 'correct number of contracts';
    ok !$c->pricing_new, 'contract is new';
    ok !$c->is_expired,  'not expired';
    is $c->bid_price, '16.47', 'has bid price, and higher because spot is higher now';

    $args->{date_pricing} = $now->plus_time_interval('12h');
    $c = produce_contract($args);
    ok $c->is_expired, 'contract is expired, this is a 10h contract';
    cmp_ok $c->number_of_contracts, '==', '0.02080', 'correct number of contracts';
};

subtest 'shortcode (legacy)' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s')->epoch;
    my $c         = produce_contract($args);
    my $shortcode = 'VANILLALONGCALL_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_69420000000_0.02080';

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

subtest 'shortcode S1P (legacy)' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s')->epoch;
    my $c         = produce_contract($args);
    my $shortcode = 'VANILLALONGCALL_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_S116181P_0.02080';

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

subtest 'shortcode' => sub {
    $args->{date_pricing} = $now->plus_time_interval('1s')->epoch;
    my $c         = produce_contract($args);
    my $shortcode = 'VANILLALONGCALL_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_69420000000_0.02080_1425945600';

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
    my $shortcode = 'VANILLALONGCALL_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_S116181P_0.02080_1425945600';

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
            "For a 'Call' contract, you receive a payout on [_3] if the final price of [_1] is above [_4]. The payout is equal to [_5] multiplied by the difference[_7]between the final price and [_4]. You may choose to sell the contract up until [_6] before [_3], and receive a contract value. ",
            ['Volatility 100 Index'],
            ['contract start time'],
            '10-Mar-15 10:00:00GMT',
            '69420.00',
            '0.02080',
            '60 seconds',
            ' '
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

    my @expected_strike_price_choices = ('+3049.60', '+1255.10', '+38.80', '-1156.10', '-2844.40');

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

    my @expected_strike_price_choices = ('64000.00', '64890.00', '65780.00', '66670.00', '68000.00', '68890.00', '69780.00', '70670.00', '72000.00');
    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');
};

subtest 'strike price choice validation' => sub {
    $args->{duration} = '10h';
    my $c = produce_contract($args);

    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'InvalidBarrier', 'correct error message';
    is $c->primary_validation_error->message_to_client->[0], 'Barriers available are +3049.60, +1255.10, +38.80, -1156.10, -2844.40',
        'correct error message to client';

    $args->{duration} = '10h';
    $args->{barrier}  = '+38.80';
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
    $args->{barrier}  = '+38.80';
    my $c = produce_contract($args);

    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message,                'maximum stake limit',            'correct error message';
    is $c->primary_validation_error->message_to_client->[0], 'Maximum stake allowed is [_1].', 'correct error message to client';

    $args->{stake}    = 10;
    $args->{duration} = '10h';
    $args->{barrier}  = '+38.80';
    $c                = produce_contract($args);

    ok $c->is_valid_to_buy, 'valid to buy now';
};

subtest 'symmetryic strike price choices ultra long duration' => sub {

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([5224.25, $now->epoch, 'R_100']);

    $per_symbol_config = JSON::MaybeXS::decode_json($per_symbol_config);
    $per_symbol_config->{max_strike_price_choice} = 5, $per_symbol_config = JSON::MaybeXS::encode_json($per_symbol_config);
    $app_config->set({'quants.vanilla.per_symbol_config.R_100_daily' => $per_symbol_config});

    $args->{duration} = '364d';
    my $c                             = produce_contract($args);
    my @expected_strike_price_choices = ('2400.00', '3800.00', '5200.00', '18000.00', '30800.00');
    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');

    $args->{duration}              = '25h';
    $c                             = produce_contract($args);
    @expected_strike_price_choices = ('4900.00', '5050.00', '5200.00', '5350.00', '5500.00');
    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');

    $args->{duration}              = '29d';
    $c                             = produce_contract($args);
    @expected_strike_price_choices = ('3800.00', '4500.00', '5200.00', '6500.00', '7800.00');
    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');

    $per_symbol_config = JSON::MaybeXS::decode_json($per_symbol_config);
    $per_symbol_config->{max_strike_price_choice} = 13, $per_symbol_config = JSON::MaybeXS::encode_json($per_symbol_config);
    $app_config->set({'quants.vanilla.per_symbol_config.R_100_daily' => $per_symbol_config});

    $args->{duration}              = '364d';
    $c                             = produce_contract($args);
    @expected_strike_price_choices = (
        '2400.00',  '2870.00',  '3340.00',  '3810.00',  '4280.00', '4750.00', '5200.00', '9470.00',
        '13740.00', '18010.00', '22280.00', '26550.00', '30800.00'
    );
    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');

    $args->{duration}              = '182d';
    $c                             = produce_contract($args);
    @expected_strike_price_choices = (
        '2700.00', '3120.00',  '3540.00',  '3960.00',  '4380.00', '4800.00', '5200.00', '7080.00',
        '8960.00', '10840.00', '12720.00', '14600.00', '16500.00'
    );
    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');
};

subtest 'check if spread is applied properly' => sub {

    my $c   = produce_contract($args);
    my $bid = $c->bid_probability->amount;
    my $ask = $c->ask_probability->amount;

    $per_symbol_config                = JSON::MaybeXS::decode_json($per_symbol_config);
    $per_symbol_config->{spread_spot} = 0.1;
    $per_symbol_config                = JSON::MaybeXS::encode_json($per_symbol_config);
    $app_config->set({'quants.vanilla.per_symbol_config.R_100_daily' => $per_symbol_config});

    $c = produce_contract($args);

    ok $c->bid_probability->amount < $bid, 'spread applied properly';
    ok $c->ask_probability->amount > $ask, 'spread applied properly';

};

subtest 'check if strike price based markup is applied properly' => sub {

    $args->{duration} = '10h';
    my $c                   = produce_contract($args);
    my $number_of_contracts = $c->number_of_contracts;

    my $markup_config = {
        "R_100" => {
            "id" => {
                "strike_price_range" => {
                    "min" => 0,
                    "max" => 99999
                },
                "contract_duration" => {
                    "min" => 0,
                    "max" => 1
                },
                "markup"           => 20,
                "trade_type"       => "VANILLALONGCALL",
                "disable_offering" => 0
            }}};
    $app_config->set({'quants.vanilla.strike_price_range_markup' => JSON::MaybeXS::encode_json($markup_config)});

    my $max_barrier = 5280;
    my $min_barrier = 4000;
    $markup_config = {
        "R_100" => {
            "id" => {
                "strike_price_range" => {
                    "min" => $min_barrier,
                    "max" => $max_barrier
                },
                "contract_duration" => {
                    "min" => 0,
                    "max" => 0.00125571    #11 hours
                },
                "markup"           => 20,
                "trade_type"       => "VANILLALONGCALL",
                "disable_offering" => 1
            }}};
    $app_config->set({'quants.vanilla.strike_price_range_markup' => JSON::MaybeXS::encode_json($markup_config)});

    $args->{barrier} = '+3.00';
    $c = produce_contract($args);

    ok $c->barrier->as_absolute < $max_barrier, 'barrier is less than max barrier';
    ok $c->barrier->as_absolute > $min_barrier, 'barrier is greater than min barrier';
    ok !$c->is_valid_to_buy,                    'not valid to buy now because strike price ranged from min_barrier and max_barrier is disabled';
    is $c->primary_validation_error->message, 'BarrierOutOfRange', 'got the right error message';

    $args->{duration} = '12h';
    $args->{barrier}  = '+3.60';
    $c                = produce_contract($args);
    ok $c->barrier->as_absolute < $max_barrier, 'barrier is less than max barrier';
    ok $c->barrier->as_absolute > $min_barrier, 'barrier is greater than min barrier';
    ok $c->is_valid_to_buy,                     'valid to buy now because contract duration is out of range';
    is $c->primary_validation_error, undef, 'got the right error message';

    $args->{barrier}  = '+233.20';
    $args->{duration} = '10h';
    $c                = produce_contract($args);
    ok $c->barrier->as_absolute > $max_barrier, 'barrier is greater than max barrier';
    ok $c->is_valid_to_buy,                     'valid to buy now because strike price is out of range';
    is $c->primary_validation_error, undef, 'got the right error message';
};

subtest 'min stake can never be greater than max stake check' => sub {
    # min stake > max stake can happen if
    #   - spot price is high valued
    #   - high volatility underlying
    #   - long duration
    #   - far ITM
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [682580.19, $now->epoch,       'R_100'],
        [694200.69, $now->epoch + 600, 'R_100'],
        [694190.48, $now->epoch + 601, 'R_100']);

    $per_symbol_config                            = JSON::MaybeXS::decode_json($per_symbol_config);
    $per_symbol_config->{min_number_of_contracts} = {'USD' => 0.1};
    $per_symbol_config                            = JSON::MaybeXS::encode_json($per_symbol_config);
    $app_config->set({'quants.vanilla.per_symbol_config.R_100_daily' => $per_symbol_config});

    $args->{duration} = '364d';
    $args->{barrier}  = '60000.00';
    my $c = produce_contract($args);

    ok $c->delta > 0.9,                'contract is deep ITM';
    ok $c->min_stake <= $c->max_stake, 'min stake is less than or equal to max stake even for deep ITM contract';
};

subtest 'affiliate commission' => sub {
    my $c               = produce_contract($args);
    my $sell_commission = $c->sell_commission;
    my $buy_commission  = $c->buy_commission;

    my $expected_bid_spread = $c->number_of_contracts * ($c->theo_probability->amount - $c->bid_probability->amount);
    my $expected_ask_spread = $c->number_of_contracts * ($c->initial_ask_probability->amount - $c->theo_probability->amount);

    is $sell_commission, $expected_bid_spread, 'correct commission';
    is $buy_commission,  $expected_ask_spread, 'correct commission';

    $args->{date_pricing} = $now->plus_time_interval('11h');
    $args->{duration}     = '10h';
    $c                    = produce_contract($args);

    is $c->is_expired,      1, 'contract is expired';
    is $c->sell_commission, 0, 'correct commission';

};

subtest 'consistent sell tick' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([68258.19, $now->epoch, 'R_100'], [69420.69, $now->epoch + 17999, 'R_100']);

    $args->{date_pricing} = $now->plus_time_interval('5h');
    my $c                    = produce_contract($args);
    my $sold_at_market_price = $c->bid_price;
    is $c->current_tick->epoch, $now->epoch + 17999, 'correct tick';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch + 18000,
        quote      => 69696.69,
    });

    # oops, sold at market but time is t + 1
    $args->{sell_price} = $sold_at_market_price;
    $args->{sell_time}  = $now->epoch + 18000;
    $c                  = produce_contract($args);
    is $c->close_tick->quote, 69420.69,            'correct tick';
    is $c->close_tick->epoch, $now->epoch + 17999, 'correct tick';

};

done_testing;

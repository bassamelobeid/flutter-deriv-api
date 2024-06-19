#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 15;
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
    cmp_ok $c->number_of_contracts, '==', '0.00609', 'correct number of contracts';
    ok !$c->is_expired, 'not expired';

    $args->{date_pricing} = $now->plus_time_interval('2s');
    $c = produce_contract($args);
    cmp_ok $c->number_of_contracts, '==', '0.00609', 'correct number of contracts';

    $args->{date_pricing} = $now->plus_time_interval('12h');
    $c = produce_contract($args);
    cmp_ok $c->number_of_contracts, '==', '0.00609', 'correct number of contracts';
};

subtest 'shortcode (legacy)' => sub {

    my $c         = produce_contract($args);
    my $shortcode = 'VANILLALONGPUT_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_69420000000_0.00609';

    my $c_shortcode;
    lives_ok {
        $c_shortcode = produce_contract($shortcode, 'USD');
    }
    'does not die trying to produce contract from short code';

    is $c->code,                 $c_shortcode->code,                 'same code';
    is $c->pricing_code,         $c_shortcode->pricing_code,         'same pricing code';
    is $c->barrier->as_absolute, $c_shortcode->barrier->as_absolute, 'same strike price';
    is $c->date_start->epoch,    $c_shortcode->date_start->epoch,    'same date start';
};

subtest 'shortcode' => sub {

    my $c         = produce_contract($args);
    my $shortcode = 'VANILLALONGPUT_R_100_10.00_' . $now->epoch . '_' . $now->plus_time_interval('10h')->epoch . '_69420000000_0.00609_1425945600';

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
            "For a 'Put' contract, you receive a payout on [_3] if the final price of [_1] is below [_4]. The payout is equal to [_5] multiplied by the difference[_7]between the final price and [_4]. You may choose to sell the contract up until [_6] before [_3], and receive a contract value. ",
            ['Volatility 100 Index'],
            ['contract start time'],
            '10-Mar-15 10:00:00GMT',
            '69420.00',
            '0.00609',
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
        isa_ok $c, 'BOM::Product::Contract::Vanillalongput';
        is $c->code, 'VANILLALONGPUT';
        ok $c->is_intraday, 'is intraday';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::BlackScholes';
        cmp_ok $c->barrier->as_absolute,                 'eq', '69420.00', 'correct absolute barrier (it will be pipsized) ';
        cmp_ok $c->entry_tick->quote,                    'eq', '68258.19', 'correct entry tick';
        cmp_ok $c->current_spot,                         'eq', '68258.19', 'correct current spot (it will be pipsized)';
        cmp_ok sprintf("%.5f", $c->number_of_contracts), 'eq', '0.00861',  'number of contrats are correct';

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

subtest 'risk management tools' => sub {
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    $args->{barrier} = 67420;    #69420 is too deep OTM for vol markup to have significant effect
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
        $args->{amount}       = '1000';

        $per_symbol_config                            = JSON::MaybeXS::decode_json($per_symbol_config);
        $per_symbol_config->{min_number_of_contracts} = {'USD' => 0};
        $per_symbol_config->{max_number_of_contracts} = {'USD' => 2};
        $per_symbol_config                            = JSON::MaybeXS::encode_json($per_symbol_config);

        $app_config->set({'quants.vanilla.per_symbol_config.R_100_intraday' => $per_symbol_config});
        $args->{barrier} = '+0.60';
        my $c = produce_contract($args);

        ok !$c->is_valid_to_buy, 'invalid to buy';
        is $c->primary_validation_error->message,                'maximum stake limit',            'correct error message';
        is $c->primary_validation_error->message_to_client->[0], 'Maximum stake allowed is [_1].', 'correct message to client';
    }
    'number of contracts validation';
};

subtest 'strike price choices intraday' => sub {
    my $c = produce_contract($args);

    my @expected_strike_price_choices = ('+381.80', '+156.40', '+0.60', '-154.70', '-378.40');

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
    $args->{amount}   = '10';
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
done_testing;

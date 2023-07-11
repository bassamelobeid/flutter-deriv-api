#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 9;
use Test::Warnings;
use Test::Exception;
use Test::Deep;
use Date::Utility;
use Storable qw(dclone);

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Product::Utils                          qw(business_days_between weeks_between);
use BOM::Product::ContractFactory                qw(produce_contract);
use BOM::Config::Runtime;

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-03-2015');

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [1.08391, $now->epoch,          'frxEURUSD'],
    [1.08390, $now->epoch + 43200,  'frxEURUSD'],
    [1.08393, $now->epoch + 86400,  'frxEURUSD'],
    [1.08390, $now->epoch + 129600, 'frxEURUSD'],
    [1.08391, $now->epoch + 172800, 'frxEURUSD'],
    [1.08385, $now->epoch + 216000, 'frxEURUSD'],
    [1.08377, $now->epoch + 223198, 'frxEURUSD'],
    [1.08375, $now->epoch + 223199, 'frxEURUSD'],
    [1.08380, $now->epoch + 223200, 'frxEURUSD'],
    [1.08385, $now->epoch + 223201, 'frxEURUSD'],
    [1.08399, $now->epoch + 259200, 'frxEURUSD']);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => $_,
    }) for qw( EUR USD EUR-USD );
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw (frxEURUSD frxAUDCAD frxUSDCAD frxAUDUSD);

my $args = {
    bet_type     => 'Vanillalongput',
    underlying   => 'frxEURUSD',
    date_start   => $now,
    date_pricing => $now,
    duration     => '2d',
    currency     => 'USD',
    amount_type  => 'stake',
    amount       => 10,
    barrier      => '1.08394',
};

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my $fx_per_symbol_config = {
    'maturities_allowed_days'  => [1, 2, 3, 4, 5],
    'maturities_allowed_weeks' => [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
    'min_number_of_contracts'  => {'USD' => 0},
    'max_number_of_contracts'  => {'USD' => 10000},
    'max_strike_price_choice'  => 10,
    'bs_markup'                => 0,
    'delta_config'             => [0.1, 0.3, 0.5, 0.7, 0.9],
    'risk_profile'             => 'low_risk',
    'spread_spot'              => {
        'delta' => {
            '0.1' => {
                'day' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                },
                'week' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                }
            },
            '0.5' => {
                'day' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                },
                'week' => {
                    '1' => 0,
                    '2' => 0,
                }
            },
            '0.9' => {
                'day' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                },
                'week' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                }}}
    },
    'spread_vol' => {
        'delta' => {
            '0.1' => {
                'day' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                },
                'week' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                }
            },
            '0.5' => {
                'day' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                },
                'week' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                }
            },
            '0.9' => {
                'day' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                },
                'week' => {
                    '1' => 0,
                    '2' => 0,
                    '3' => 0
                }}}}};

my $spread_specific_time = {
    'frxEURUSD' => {
        '0.1' => {
            '1D' => {
                'abcd1234' => {
                    'end_time'    => '2015-03-10 00:00:00',
                    'spread_spot' => 0,
                    'spread_vol'  => 0,
                    'start_time'  => '2015-03-09 00:00:00'
                }
            },
        },
        '0.5' => {
            '2D' => {
                'abce3214' => {
                    'end_time'    => '2015-03-10 21:45:00',
                    'spread_spot' => 0,
                    'spread_vol'  => 0,
                    'start_time'  => '2015-03-09 00:00:00'
                }
            },
        }}};
$fx_per_symbol_config = JSON::MaybeXS::encode_json($fx_per_symbol_config);
$spread_specific_time = JSON::MaybeXS::encode_json($spread_specific_time);
$app_config->set({'quants.vanilla.fx_per_symbol_config.frxEURUSD' => $fx_per_symbol_config});
$app_config->set({'quants.vanilla.fx_spread_specific_time'        => $spread_specific_time});

my $risk_profile_config = {'USD' => 20};
$risk_profile_config = JSON::MaybeXS::encode_json($risk_profile_config);

$app_config->set({'quants.vanilla.risk_profile.low_risk' => $risk_profile_config});

subtest 'basic produce_contract' => sub {

    my $c = produce_contract($args);
    isa_ok $c, 'BOM::Product::Contract::Vanillalongput';
    is $c->code,         'VANILLALONGPUT';
    is $c->pricing_code, 'VANILLA_PUT';
    ok !$c->is_intraday,       'is not intraday';
    ok !$c->is_path_dependent, 'is not path dependent';
    isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::BlackScholes';
    isa_ok $c->barrier,        'BOM::Product::Contract::Strike';
    ok $c->pricing_new, 'this is a new contract';

    # Refer Vanillalongput.pm for the formula
    is sprintf("%.5f", $c->bid_probability->amount), '0.00650', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.00650', 'correct ask probability';

};

subtest 'longcode' => sub {
    my $c = produce_contract($args);
    is_deeply(
        $c->longcode,
        [
            "For a 'Put' contract, you receive a payout on [_3] if the final price of [_1] is below [_4]. The payout is equal to [_5] multiplied by the difference[_7]between the final price and [_4]. You may choose to sell the contract up until [_6] before [_3], and receive a contract value. ",
            ['EUR/USD'],
            [],
            '12-Mar-15 14:00:00GMT',
            '1.08394',
            '0.01539',
            '24 hours',
            ', in pips, '
        ],
        'longcode matches'
    );
};

subtest 'check spread spot and spread vol is applied (specific time)' => sub {

    my $new_args = dclone($args);

    my $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                                             '-0.5',    'delta is approximately -0.5';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,         '2 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount),                           '0.00650', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount),                           '0.00650', 'correct ask probability';

    # same duration, different delta
    $new_args->{barrier} = '1.06';
    my $c1       = produce_contract($new_args);
    my $c1_delta = $c1->delta;
    my $c1_ask   = $c1->ask_probability->amount;
    my $c1_bid   = $c1->bid_probability->amount;
    is sprintf("%.1f", $c1_delta),                                             '-0.2',    'delta is approximately -0.2';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,         '2 days expiry contract';
    is sprintf("%.5f", $c1_bid),                                               '0.00389', 'correct bid probability';
    is sprintf("%.5f", $c1_ask),                                               '0.00389', 'correct ask probability';

    $new_args->{barrier}  = '1.08394';
    $new_args->{duration} = '1d';
    my $c2       = produce_contract($new_args);
    my $c2_delta = $c2->delta;
    my $c2_ask   = $c2->ask_probability->amount;
    my $c2_bid   = $c2->bid_probability->amount;

    is business_days_between($c2->date_start, $c2->date_expiry, $c2->underlying), 1, '1 days expiry contract';
    is sprintf("%.5f", $c2_bid), '0.00511', 'correct bid probability';
    is sprintf("%.5f", $c2_ask), '0.00511', 'correct ask probability';

    # add spread to  delta 0.5 and expiry 2 days contract should become more expensive
    $spread_specific_time                                                          = JSON::MaybeXS::decode_json($spread_specific_time);
    $spread_specific_time->{frxEURUSD}->{0.5}->{'2D'}->{'abce3214'}->{spread_spot} = 0.001;
    $spread_specific_time->{frxEURUSD}->{0.5}->{'2D'}->{'abce3214'}->{spread_vol}  = 0.001;
    $spread_specific_time                                                          = JSON::MaybeXS::encode_json($spread_specific_time);

    $app_config->set({'quants.vanilla.fx_spread_specific_time' => $spread_specific_time});

    $new_args->{duration} = '2d';
    $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                                             '-0.5',    'delta is approximately -0.5';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,         '2 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount),                           '0.00623', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount),                           '0.00676', 'correct ask probability';

    # these contract shouldn't be more expensive as there is no markup
    $new_args->{barrier}  = '1.06';
    $new_args->{duration} = '2d';
    $c                    = produce_contract($new_args);
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,       '2 days expiry contract';
    is $c->bid_probability->amount,                                            $c1_bid, 'correct bid probability';
    is $c->ask_probability->amount,                                            $c1_ask, 'correct ask probability';

    $new_args->{duration} = '1d';
    $new_args->{barrier}  = '1.08394';
    $c                    = produce_contract($new_args);
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 1,       '1 days expiry contract';
    is $c->bid_probability->amount,                                            $c2_bid, 'correct bid probability';
    is $c->ask_probability->amount,                                            $c2_ask, 'correct ask probability';

    $spread_specific_time = JSON::MaybeXS::decode_json($spread_specific_time);
    delete $spread_specific_time->{frxEURUSD}->{0.5}->{'2D'}->{'abce3214'};
    $spread_specific_time = JSON::MaybeXS::encode_json($spread_specific_time);

    $app_config->set({'quants.vanilla.fx_spread_specific_time' => $spread_specific_time});

};

subtest 'check spread spot and spread vol is applied (days)' => sub {

    my $new_args = dclone($args);

    my $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                                             '-0.5',    'delta is approximately -0.5';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,         '2 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount),                           '0.00650', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount),                           '0.00650', 'correct ask probability';

    $new_args->{duration} = '1d';
    $c = produce_contract($new_args);
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 1, '1 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '0.00511', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.00511', 'correct ask probability';

    # add spread to  delta 0.5 and expiry 2 days contract should become more expensive
    $fx_per_symbol_config                                            = JSON::MaybeXS::decode_json($fx_per_symbol_config);
    $fx_per_symbol_config->{spread_spot}->{delta}->{0.5}->{day}->{2} = 0.01;
    $fx_per_symbol_config->{spread_vol}->{delta}->{0.5}->{day}->{2}  = 0.01;
    $fx_per_symbol_config                                            = JSON::MaybeXS::encode_json($fx_per_symbol_config);

    $app_config->set({'quants.vanilla.fx_per_symbol_config.frxEURUSD' => $fx_per_symbol_config});

    $new_args->{duration} = '2d';
    $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                                             '-0.5', 'delta is approximately -0.5';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,      '2 days expiry contract';

    is sprintf("%.5f", $c->bid_probability->amount), '0.00383', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.00917', 'correct ask probability';

    # this contract shouldn't be more expensive as there is no markup
    $new_args->{duration} = '1d';
    $c = produce_contract($new_args);
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 1, '1 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '0.00511', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.00511', 'correct ask probability';

    $fx_per_symbol_config                                            = JSON::MaybeXS::decode_json($fx_per_symbol_config);
    $fx_per_symbol_config->{spread_spot}->{delta}->{0.5}->{day}->{3} = 0;
    $fx_per_symbol_config->{spread_vol}->{delta}->{0.5}->{day}->{3}  = 0;
    $fx_per_symbol_config                                            = JSON::MaybeXS::encode_json($fx_per_symbol_config);

    $app_config->set({'quants.vanilla.fx_per_symbol_config.frxEURUSD' => $fx_per_symbol_config});

};

subtest 'check spread spot and spread vol is applied (weeks)' => sub {

    my $new_args = dclone($args);

    # > 7 days to account for weekends
    $new_args->{duration} = '10d';
    my $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                     '-0.5',    'delta is approximately -0.5';
    is weeks_between($c->date_start, $c->date_expiry), 1,         '1 week expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount),   '0.01165', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount),   '0.01165', 'correct ask probability';

    $new_args->{duration} = '14d';
    $c = produce_contract($new_args);
    is weeks_between($c->date_start, $c->date_expiry), 2, '2 week expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '0.01288', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.01288', 'correct ask probability';

    # add spread to  delta 0.5 and expiry 3 days contract should become more expensive
    $fx_per_symbol_config                                             = JSON::MaybeXS::decode_json($fx_per_symbol_config);
    $fx_per_symbol_config->{spread_spot}->{delta}->{0.5}->{week}->{2} = 0.01;
    $fx_per_symbol_config->{spread_vol}->{delta}->{0.5}->{week}->{2}  = 0.01;
    $fx_per_symbol_config                                             = JSON::MaybeXS::encode_json($fx_per_symbol_config);

    $app_config->set({'quants.vanilla.fx_per_symbol_config.frxEURUSD' => $fx_per_symbol_config});

    $new_args->{duration} = '14d';
    $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                     '-0.5', 'delta is approximately -0.5';
    is weeks_between($c->date_start, $c->date_expiry), 2,      '2 week expiry contract';

    is sprintf("%.5f", $c->bid_probability->amount), '0.00998', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.01579', 'correct ask probability';

    # this contract shouldn't be more expensive as there is no markup
    $new_args->{duration} = '10d';
    $c = produce_contract($new_args);
    is weeks_between($c->date_start, $c->date_expiry), 1, '1 week expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '0.01165', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.01165', 'correct ask probability';

    $fx_per_symbol_config                                             = JSON::MaybeXS::decode_json($fx_per_symbol_config);
    $fx_per_symbol_config->{spread_spot}->{delta}->{0.5}->{week}->{2} = 0;
    $fx_per_symbol_config->{spread_vol}->{delta}->{0.5}->{week}->{2}  = 0;
    $fx_per_symbol_config                                             = JSON::MaybeXS::encode_json($fx_per_symbol_config);

    $app_config->set({'quants.vanilla.fx_per_symbol_config.frxEURUSD' => $fx_per_symbol_config});
};

subtest 'check correct exit tick' => sub {

    my $new_args = dclone($args);
    $new_args->{date_pricing} = $now->plus_time_interval('3d');
    my $c = produce_contract($new_args);

    is $c->exit_tick->epoch, $c->date_expiry->epoch, 'exit tick is at 10am NYT';
};

subtest 'vanilla financials expire at 10am NYT' => sub {

    my $new_args = dclone($args);
    $new_args->{duration} = '10h';
    $new_args->{barrier}  = '1.08400';
    my $c = produce_contract($new_args);

    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message,                'InvalidExpiry',                   'correct error message';
    is $c->primary_validation_error->message_to_client->[0], 'Contract cannot end at same day', 'correct error message to client';

    $new_args = dclone($args);

    $new_args->{duration} = '2d';
    $new_args->{barrier}  = '1.08400';
    $c                    = produce_contract($new_args);
    ok $c->is_valid_to_buy, 'valid to buy';

    $new_args->{duration} = '9d';
    $new_args->{barrier}  = '1.08400';
    $c                    = produce_contract($new_args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message,                'InvalidExpiry',                                'correct error message';
    is $c->primary_validation_error->message_to_client->[0], 'Contract more than 1 week must end on Friday', 'correct error message to client';

    $new_args->{duration} = '365d';
    $new_args->{barrier}  = '1.08400';
    $c                    = produce_contract($new_args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'InvalidExpiry', 'correct error message';
    is $c->primary_validation_error->message_to_client->[0],
        'Invalid contract duration. Durations offered are (1 2 3 4 5) days and every Friday after (1 2 3 4 5 6 7 8 9 10) weeks.',
        'correct error message to client';

};

subtest 'strike price choices >intraday' => sub {

    $args->{duration} = '7d';
    my $c = produce_contract($args);

    my @expected_strike_price_choices = ('1.02900', '1.04122', '1.05344', '1.06567', '1.08400', '1.09356', '1.10311', '1.11267', '1.12700');

    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');
};

done_testing;

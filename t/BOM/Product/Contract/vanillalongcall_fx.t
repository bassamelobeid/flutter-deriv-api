#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 10;
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
    [132.185, $now->epoch,          'frxUSDJPY'],
    [132.173, $now->epoch + 43200,  'frxUSDJPY'],
    [132.145, $now->epoch + 86400,  'frxUSDJPY'],
    [132.150, $now->epoch + 129600, 'frxUSDJPY'],
    [132.149, $now->epoch + 172800, 'frxUSDJPY'],
    [132.161, $now->epoch + 216000, 'frxUSDJPY'],
    [132.69,  $now->epoch + 223198, 'frxUSDJPY'],
    [132.169, $now->epoch + 223199, 'frxUSDJPY'],
    [132.694, $now->epoch + 223200, 'frxUSDJPY'],
    [132.642, $now->epoch + 223201, 'frxUSDJPY'],
    [132.162, $now->epoch + 259200, 'frxUSDJPY']);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => $_,
    }) for qw( USD JPY JPY-USD );
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw (frxUSDJPY frxAUDCAD frxUSDCAD frxAUDUSD);

my $args = {
    bet_type     => 'Vanillalongcall',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '2d',
    currency     => 'USD',
    amount_type  => 'stake',
    amount       => 10,
    barrier      => '132.17',
};

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my $fx_per_symbol_config = {
    'maturities_allowed_days'  => [1, 2, 3, 4, 5],
    'maturities_allowed_weeks' => [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
    'min_number_of_contracts'  => {'USD' => 0},
    'max_number_of_contracts'  => {'USD' => 1000},
    'max_strike_price_choice'  => 10,
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
    'frxUSDJPY' => {
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
$app_config->set({'quants.vanilla.fx_per_symbol_config.frxUSDJPY' => $fx_per_symbol_config});
$app_config->set({'quants.vanilla.fx_spread_specific_time'        => $spread_specific_time});

my $risk_profile_config = {'USD' => 20};
$risk_profile_config = JSON::MaybeXS::encode_json($risk_profile_config);

$app_config->set({'quants.vanilla.risk_profile.low_risk' => $risk_profile_config});

subtest 'basic produce_contract' => sub {

    my $c = produce_contract($args);
    isa_ok $c, 'BOM::Product::Contract::Vanillalongcall';
    is $c->code,         'VANILLALONGCALL';
    is $c->pricing_code, 'VANILLA_CALL';
    ok !$c->is_intraday,       'is not intraday';
    ok !$c->is_path_dependent, 'is not path dependent';
    isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::BlackScholes';
    isa_ok $c->barrier,        'BOM::Product::Contract::Strike';
    ok $c->pricing_new, 'this is a new contract';

    # Refer Vanillalongcall.pm for the formula
    is sprintf("%.5f", $c->bid_probability->amount), '0.81152', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.81152', 'correct ask probability';

};

subtest 'longcode' => sub {
    my $c = produce_contract($args);
    is_deeply(
        $c->longcode,
        [
            "For a 'Call' contract, you receive a payout on [_3] if the final price of [_1] is above [_4]. The payout is equal to [_5] multiplied by the difference[_7]between the final price and [_4]. You may choose to sell the contract up until [_6] before [_3], and receive a contract value. ",
            ['USD/JPY'],
            [],
            '12-Mar-15 14:00:00GMT',
            '132.170',
            '0.01232',
            '24 hours',
            ', in pips, '
        ],
        'longcode matches'
    );
};

subtest 'check spread spot and spread vol is applied (specific time)' => sub {

    my $new_args = dclone($args);

    my $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                                             '0.5',     'delta is approximately 0.5';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,         '2 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount),                           '0.81152', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount),                           '0.81152', 'correct ask probability';

    # same duration, different delta
    $new_args->{barrier} = '135.12';
    $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                                             '0.1',     'delta is approximately 0.1';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,         '2 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount),                           '0.20901', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount),                           '0.20901', 'correct ask probability';

    $new_args->{barrier}  = '132.17';
    $new_args->{duration} = '1d';
    $c                    = produce_contract($new_args);
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 1, '1 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '0.63756', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.63756', 'correct ask probability';

    # add spread to  delta 0.5 and expiry 2 days contract should become more expensive
    $spread_specific_time                                                          = JSON::MaybeXS::decode_json($spread_specific_time);
    $spread_specific_time->{frxUSDJPY}->{0.5}->{'2D'}->{'abce3214'}->{spread_spot} = 0.012;
    $spread_specific_time->{frxUSDJPY}->{0.5}->{'2D'}->{'abce3214'}->{spread_vol}  = 0.023;
    $spread_specific_time                                                          = JSON::MaybeXS::encode_json($spread_specific_time);

    $app_config->set({'quants.vanilla.fx_spread_specific_time' => $spread_specific_time});

    $new_args->{duration} = '2d';
    $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                                             '0.5',     'delta is approximately 0.5';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,         '2 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount),                           '0.75745', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount),                           '0.86559', 'correct ask probability';

    # these contract shouldn't be more expensive as there is no markup
    $new_args->{barrier}  = '135.12';
    $new_args->{duration} = '2d';
    $c                    = produce_contract($new_args);
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2, '2 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '0.20901', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.20901', 'correct ask probability';

    $new_args->{duration} = '1d';
    $new_args->{barrier}  = '132.17';
    $c                    = produce_contract($new_args);
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 1, '1 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '0.63756', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.63756', 'correct ask probability';

    $spread_specific_time = JSON::MaybeXS::decode_json($spread_specific_time);
    delete $spread_specific_time->{frxUSDJPY}->{0.5}->{'2D'}->{'abce3214'};
    $spread_specific_time = JSON::MaybeXS::encode_json($spread_specific_time);

    $app_config->set({'quants.vanilla.fx_spread_specific_time' => $spread_specific_time});

};

subtest 'check spread spot and spread vol is applied (days)' => sub {

    my $new_args = dclone($args);

    my $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                                             '0.5',     'delta is approximately 0.5';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,         '2 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount),                           '0.81152', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount),                           '0.81152', 'correct ask probability';

    $new_args->{duration} = '1d';
    $c = produce_contract($new_args);
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 1, '1 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '0.63756', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.63756', 'correct ask probability';

    # add spread to  delta 0.5 and expiry 2 days contract should become more expensive
    $fx_per_symbol_config                                            = JSON::MaybeXS::decode_json($fx_per_symbol_config);
    $fx_per_symbol_config->{spread_spot}->{delta}->{0.5}->{day}->{2} = 0.01;
    $fx_per_symbol_config->{spread_vol}->{delta}->{0.5}->{day}->{2}  = 0.01;
    $fx_per_symbol_config                                            = JSON::MaybeXS::encode_json($fx_per_symbol_config);

    $app_config->set({'quants.vanilla.fx_per_symbol_config.frxUSDJPY' => $fx_per_symbol_config});

    $new_args->{duration} = '2d';
    $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                                             '0.5', 'delta is approximately 0.5';
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 2,     '2 days expiry contract';

    is sprintf("%.5f", $c->bid_probability->amount), '0.78679', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.83626', 'correct ask probability';

    # this contract shouldn't be more expensive as there is no markup
    $new_args->{duration} = '1d';
    $c = produce_contract($new_args);
    is business_days_between($c->date_start, $c->date_expiry, $c->underlying), 1, '1 days expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '0.63756', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '0.63756', 'correct ask probability';

    $fx_per_symbol_config                                            = JSON::MaybeXS::decode_json($fx_per_symbol_config);
    $fx_per_symbol_config->{spread_spot}->{delta}->{0.5}->{day}->{3} = 0;
    $fx_per_symbol_config->{spread_vol}->{delta}->{0.5}->{day}->{3}  = 0;
    $fx_per_symbol_config                                            = JSON::MaybeXS::encode_json($fx_per_symbol_config);

    $app_config->set({'quants.vanilla.fx_per_symbol_config.frxUSDJPY' => $fx_per_symbol_config});
};

subtest 'check spread spot and spread vol is applied (weeks)' => sub {

    my $new_args = dclone($args);

    # > 7 days to account for weekends
    $new_args->{duration} = '10d';
    my $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                     '0.5',     'delta is approximately 0.5';
    is weeks_between($c->date_start, $c->date_expiry), 1,         '1 week expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount),   '1.47114', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount),   '1.47114', 'correct ask probability';

    $new_args->{duration} = '14d';
    $c = produce_contract($new_args);
    is weeks_between($c->date_start, $c->date_expiry), 2, '2 week expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '1.63456', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '1.63456', 'correct ask probability';

    # add spread to  delta 0.5 and expiry 3 days contract should become more expensive
    $fx_per_symbol_config                                             = JSON::MaybeXS::decode_json($fx_per_symbol_config);
    $fx_per_symbol_config->{spread_spot}->{delta}->{0.5}->{week}->{2} = 0.01;
    $fx_per_symbol_config->{spread_vol}->{delta}->{0.5}->{week}->{2}  = 0.01;
    $fx_per_symbol_config                                             = JSON::MaybeXS::encode_json($fx_per_symbol_config);

    $app_config->set({'quants.vanilla.fx_per_symbol_config.frxUSDJPY' => $fx_per_symbol_config});

    $new_args->{duration} = '14d';
    $c = produce_contract($new_args);
    is sprintf("%.1f", $c->delta),                     '0.5', 'delta is approximately 0.5';
    is weeks_between($c->date_start, $c->date_expiry), 2,     '2 week expiry contract';

    is sprintf("%.5f", $c->bid_probability->amount), '1.57933', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '1.68979', 'correct ask probability';

    # this contract shouldn't be more expensive as there is no markup
    $new_args->{duration} = '10d';
    $c = produce_contract($new_args);
    is weeks_between($c->date_start, $c->date_expiry), 1, '1 week expiry contract';
    is sprintf("%.5f", $c->bid_probability->amount), '1.47114', 'correct bid probability';
    is sprintf("%.5f", $c->ask_probability->amount), '1.47114', 'correct ask probability';

    $fx_per_symbol_config                                             = JSON::MaybeXS::decode_json($fx_per_symbol_config);
    $fx_per_symbol_config->{spread_spot}->{delta}->{0.5}->{week}->{2} = 0;
    $fx_per_symbol_config->{spread_vol}->{delta}->{0.5}->{week}->{2}  = 0;
    $fx_per_symbol_config                                             = JSON::MaybeXS::encode_json($fx_per_symbol_config);

    $app_config->set({'quants.vanilla.fx_per_symbol_config.frxUSDJPY' => $fx_per_symbol_config});
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
    $new_args->{barrier}  = '130.200';

    my $c = produce_contract($new_args);

    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message,                'InvalidExpiry',                   'correct error message';
    is $c->primary_validation_error->message_to_client->[0], 'Contract cannot end at same day', 'correct error message to client';

    $new_args = dclone($args);

    $new_args->{duration} = '2d';
    $new_args->{barrier}  = '132.200';
    $c                    = produce_contract($new_args);
    ok $c->is_valid_to_buy, 'valid to buy';

    $new_args->{duration} = '9d';
    $new_args->{barrier}  = '132.200';
    $c                    = produce_contract($new_args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message,                'InvalidExpiry',                                'correct error message';
    is $c->primary_validation_error->message_to_client->[0], 'Contract more than 1 week must end on Friday', 'correct error message to client';

    $new_args->{duration} = '365d';
    $new_args->{barrier}  = '132.200';
    $c                    = produce_contract($new_args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'InvalidExpiry', 'correct error message';
    is $c->primary_validation_error->message_to_client->[0],
        'Invalid contract duration. Durations offered are (1 2 3 4 5) days and every Friday after (1 2 3 4 5 6 7 8 9 10) weeks.',
        'correct error message to client';

};

subtest 'strike price choices >intraday' => sub {

    $args->{duration} = '1d';
    my $c = produce_contract($args);

    my @expected_strike_price_choices = ('128.600', '129.400', '130.200', '131.000', '132.200', '132.711', '133.222', '133.733', '134.500');

    cmp_deeply($c->strike_price_choices, \@expected_strike_price_choices, 'got the right strike price choices');
};

subtest 'entry and exit tick' => sub {
    lives_ok {
        $args->{duration}     = '2d';
        $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        cmp_ok sprintf("%.5f", $c->number_of_contracts), 'eq', '0.01196', 'number of contracts are correct';

        $args->{date_pricing}        = $now->plus_time_interval('3d');
        $args->{number_of_contracts} = $c->number_of_contracts;
        $c                           = produce_contract($args);
        cmp_ok sprintf("%.5f", $c->number_of_contracts), 'eq', '0.01196', 'number of contracts are correct';
        ok $c->is_expired, 'expired';
        is $c->entry_tick->quote,    '132.185', 'correct entry tick';
        is $c->barrier->as_absolute, '132.170', 'correct strike price';
        is $c->exit_tick->quote,     '132.694', 'correct exit tick';
        is $c->value,                '6.27',    '(132.694 - 132.170) * (0.01196/0.001), but rounded to 2 dp due to USD being the currency';
    }
    'winning the contract';

    lives_ok {
        delete $args->{number_of_contracts};
        $args->{bet_type}     = 'Vanillalongput', $args->{duration} = '2d';
        $args->{date_pricing} = $now;
        $args->{barrier}      = '132.800';
        my $c = produce_contract($args);
        cmp_ok sprintf("%.5f", $c->number_of_contracts), 'eq', '0.00891', 'number of contracts are correct';

        $args->{date_pricing}        = $now->plus_time_interval('3d');
        $args->{number_of_contracts} = $c->number_of_contracts;
        $c                           = produce_contract($args);
        cmp_ok sprintf("%.5f", $c->number_of_contracts), 'eq', '0.00891', 'number of contracts are correct';
        ok $c->is_expired, 'expired';
        is $c->entry_tick->quote,    '132.185', 'correct entry tick';
        is $c->barrier->as_absolute, '132.800', 'correct strike price';
        is $c->exit_tick->quote,     '132.694', 'correct exit tick';
        is $c->value,                '0.94',    '(132.800 - 132.694) * (0.00891/0.001), but rounded to 2 dp due to USD being the currency';
    }
    'winning the contract';

};

done_testing;

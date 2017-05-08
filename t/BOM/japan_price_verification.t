#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use Test::FailWarnings;
use Date::Utility;
use LandingCompany::Offerings qw(reinitialise_offerings);

use BOM::JapanContractDetails;
use BOM::MarketData qw(create_underlying);
use BOM::Market::DataDecimate;
use BOM::Platform::RedisReplicated;
use Data::Decimate qw(decimate);

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Format::Util::Numbers qw(roundnear);
use YAML::XS qw(LoadFile);

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom-test/feed/combined/');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');
my $volsurfaces = {
    1352345145 => LoadFile('/home/git/regentmarkets/bom-test/data/20121108_volsurfaces.yml'),
    1491448384 => LoadFile('/home/git/regentmarkets/bom-test/data/20170406_volsurfaces.yml'),
};
my $news = {
    1352345145 => LoadFile('/home/git/regentmarkets/bom-test/data/20121108_news.yml'),
    1491448384 => LoadFile('/home/git/regentmarkets/bom-test/data/20170406_news.yml'),
};
my $holidays = {
    1352345145 => LoadFile('/home/git/regentmarkets/bom-test/data/20121108_holidays.yml'),
    1491448384 => LoadFile('/home/git/regentmarkets/bom-test/data/20170406_holidays.yml'),
};

my $underlying = create_underlying('frxUSDJPY');
my $now        = Date::Utility->new(1352345145);

my $start = $now->epoch - 3600;
$start = $start - $start % 15;
my $first_agg = $start - 15;

my $hist_ticks = $underlying->ticks_in_between_start_end({
    start_time => $first_agg,
    end_time   => $now->epoch,
});

my @tmp_ticks = reverse @$hist_ticks;

my $decimate_cache = BOM::Market::DataDecimate->new;

my $key          = $decimate_cache->_make_key('frxUSDJPY', 0);
my $decimate_key = $decimate_cache->_make_key('frxUSDJPY', 1);

foreach my $single_data (@tmp_ticks) {
    $decimate_cache->_update($decimate_cache->redis_write, $key, $single_data->{epoch}, $decimate_cache->encoder->encode($single_data));
}

my $decimate_data = Data::Decimate::decimate($decimate_cache->sampling_frequency->seconds, \@tmp_ticks);

foreach my $single_data (@$decimate_data) {
    $decimate_cache->_update(
        $decimate_cache->redis_write,
        $decimate_key,
        $single_data->{decimate_epoch},
        $decimate_cache->encoder->encode($single_data));
}

sub prepare_market_data {
    my $date = shift;
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {events => $news->{$date->epoch}});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'holiday',
        {
            recorded_date => $date,
            calendar      => $holidays->{$date->epoch},
        });

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $underlying->symbol,
            recorded_date => Date::Utility->new($volsurfaces->{$date->epoch}->{$underlying->symbol}->{date}),
            surface       => $volsurfaces->{$date->epoch}->{$underlying->symbol}->{surfaces}->{'New York 10:00'}
                // $volsurfaces->{$date->epoch}->{$underlying->symbol}->{surface},
        });

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $date
        }) for ('USD', 'JPY-USD', 'JPY');

    Volatility::Seasonality->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
        )->generate_economic_event_seasonality({
            underlying_symbol => $underlying->symbol,
            economic_events   => $news->{$date->epoch}});
}
prepare_market_data($now);

subtest 'verify_with_shortcode_IH' => sub {
    my $expected_parameters = {
        'intraday_vega_correction' => {
            'intraday_vega'                 => '0.848243181847673',
            'historical_vol_mean_reversion' => '0.10',
            'long_term_prediction'          => '0.042722921104659'
        },
        'opposite_contract' => {
            'opposite_contract_intraday_eod_markup'                    => 0,
            'opposite_contract_vol_spread_markup'                      => '0.0128023919099228',
            'opposite_contract_long_term_prediction'                   => '0.042722921104659',
            'opposite_contract_t'                                      => '2.85388127853881e-05',
            'opposite_contract_intraday_historical_iv_risk'            => 0,
            'opposite_contract_short_term_kurtosis_risk_markup'        => 0,
            'opposite_contract_intraday_delta_correction'              => '-0.0102280185840583',
            'opposite_contract_intraday_vega'                          => '-0.848243181847673',
            'opposite_contract_discount_rate'                          => 0,
            'opposite_contract_vol'                                    => '0.0572705705513252',
            'opposite_contract_mu'                                     => 0,
            'opposite_contract_short_term_delta_correction'            => '-0.0131432219167099',
            'opposite_contract_commission_multiplier'                  => '1',
            'opposite_contract_payout'                                 => '1000',
            'opposite_contract_intraday_vega_correction'               => '-0.0036239426535643',
            'opposite_contract_quiet_period_markup'                    => 0,
            'opposite_contract_economic_events_markup'                 => '0.00286997277758383',
            'opposite_contract_economic_events_volatility_risk_markup' => '0.00286997277758383',
            'opposite_contract_economic_events_spot_risk_markup'       => 0,
            'opposite_contract_S'                                      => '79.817',
            'opposite_contract_bs_probability'                         => '0.548946852745943',
            'opposite_contract_risk_markup'                            => '0.0156723646875066',
            'opposite_contract_long_term_delta_correction'             => '-0.00731281525140659',
            'opposite_contract_historical_vol_mean_reversion'          => '0.10',
            'opposite_contract_base_commission'                        => '0.005',
            'opposite_contract_commission_markup'                      => '0.005',
            'opposite_contract_K'                                      => '79.820'
        },
        'ask_probability' => {
            'intraday_vega_correction'  => '0.0036239426535643',
            'risk_markup'               => '0.0128023919099228',
            'bs_probability'            => '0.451053147254057',
            'intraday_delta_correction' => '0.0102280185840583',
            'commission_markup'         => '0.005'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.0572705705513252',
            'K'             => '79.820',
            'mu'            => 0,
            'discount_rate' => 0,
            't'             => '2.85388127853881e-05',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'quiet_period_markup'                    => 0,
            'short_term_kurtosis_risk_markup'        => 0,
            'vol_spread_markup'                      => 0.0128023919099228,
            'intraday_eod_markup'                    => 0,
            'economic_events_markup'                 => 0,
            'economic_events_spot_risk_markup'       => 0,
            'economic_events_volatility_risk_markup' => 0,
            'intraday_historical_iv_risk'            => 0
        },
        'intraday_delta_correction' => {
            'short_term_delta_correction' => '0.0131432219167099',
            'long_term_delta_correction'  => '0.00731281525140659'
        },
        'commission_markup' => {
            'base_commission'       => '0.005',
            'commission_multiplier' => '1'
        },
        'contract_details' => {
            'ccy'         => 'JPY',
            'short_code'  => 'CALLE_FRXUSDJPY_1000_1352345145_1352346045_S3P_0',
            'trade_time'  => '2012-11-08 03:25:45',
            'description' => 'Win payout if USD/JPY is higher than or equal to entry spot plus  3 pips at 15 minutes after contract start time.',
            'tick_before_trade_time' => '79.817',
            'payout'                 => '1000',
            'loginID'                => 'NA',
            'trans_id'               => 'NA',
            'order_type'             => 'buy',
            'order_price'            => 520,
            'slippage_price'         => 'NA',
            'trade_ask_price'        => 'NA',
            'trade_bid_price'        => 'NA',
            'ref_spot'               => 'NA',
            'ref_vol'                => 'NA',
            'ref_vol2'               => 'NA'
        }};

    my $args;
    $args->{landing_company} = 'japan';
    $args->{shortcode}       = 'CALLE_FRXUSDJPY_1000_1352345145_1352346045_S3P_0';
    $args->{contract_price}  = 520;
    $args->{currency}        = 'JPY';
    $args->{action_type}     = 'buy';
    my $pricing_parameters = BOM::JapanContractDetails::verify_with_shortcode($args);
    $pricing_parameters = BOM::JapanContractDetails::include_contract_details(
        $pricing_parameters,
        {
            order_type  => 'buy',
            order_price => 520
        });

    my @expected_key = sort keys %{$expected_parameters};
    my @actual_key   = sort keys %{$pricing_parameters};
    cmp_deeply(\@expected_key, \@actual_key, 'Getting expected pricing parameters');

    my $ask_prob;
    foreach my $key (keys %{$pricing_parameters->{ask_probability}}) {
        $ask_prob += $pricing_parameters->{ask_probability}->{$key};
    }

    is(roundnear(1, $ask_prob * 1000), 483, 'Ask price is matching');
    foreach my $key (keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }

    }
};

subtest 'verify_with_shortcode_Slope' => sub {
    my $expected_parameters = {
        'risk_markup' => {
            'spot_spread_markup' => '0.00308207828274131',
            'vol_spread_markup'  => '0.020835893413195'
        },
        'bs_probability' => {
            'call_payout'        => '1000',
            'call_vol'           => '0.0726586166126899',
            'call_S'             => '79.817',
            'call_discount_rate' => '0.026681002490942',
            'call_t'             => '0.0321427891933029',
            'call_mu'            => 0,
            'call_K'             => '78.300'
        },
        'opposite_contract' => {
            'opposite_contract_put_K'                   => '78.300',
            'opposite_contract_vol_spread_markup'       => '0.020835893413195',
            'opposite_contract_spot_spread_markup'      => '0.00308207828274131',
            'opposite_contract_put_mu'                  => 0,
            'opposite_contract_put_vol'                 => '0.0726586166126899',
            'opposite_contract_put_payout'              => '1000',
            'opposite_contract_commission_multiplier'   => '1',
            'opposite_contract_put_vanilla_vega'        => '1.90900714802341',
            'opposite_contract_put_slope'               => '-0.00260796695446264',
            'opposite_contract_put_S'                   => '79.817',
            'opposite_contract_put_discount_rate'       => '0.026681002490942',
            'opposite_contract_risk_markup'             => '0.0119589858479682',
            'opposite_contract_put_weight'              => 1,
            'opposite_contract_base_commission'         => '0.005',
            'opposite_contract_commission_markup'       => '0.005',
            'opposite_contract_put_t'                   => '0.0321427891933029',
            'opposite_contract_theoretical_probability' => '0.0662095355848979'
        },
        'commission_markup' => {
            'base_commission'       => '0.005',
            'commission_multiplier' => '1'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.932933230211924',
            'risk_markup'             => '0.0119589858479682',
            'commission_markup'       => '0.005'
        },
        'contract_details' => {
            'ref_spot'               => 'NA',
            'ref_vol2'               => 'NA',
            'order_type'             => 'buy',
            'ref_vol'                => 'NA',
            'trade_bid_price'        => 'NA',
            'loginID'                => 'NA',
            'tick_before_trade_time' => '79.817',
            'short_code'             => 'CALLE_FRXUSDJPY_1000_1352345145_1353358800_78300000_0',
            'ccy'                    => 'JPY',
            'description'            => 'Win payout if USD/JPY is higher than or equal to 78.300 at 2012-11-19 21:00:00 GMT.',
            'trans_id'               => 'NA',
            'order_price'            => 928,
            'trade_time'             => '2012-11-08 03:25:45',
            'slippage_price'         => 'NA',
            'trade_ask_price'        => 'NA',
            'payout'                 => '1000'
        },
        'slope_adjustment' => {
            'call_weight'       => -1,
            'call_slope'        => '-0.00260796695446264',
            'call_vanilla_vega' => '1.90900714802341',
        }};
    my $args;
    $args->{landing_company} = 'japan';
    $args->{shortcode}       = 'CALLE_FRXUSDJPY_1000_1352345145_1353358800_78300000_0';
    $args->{contract_price}  = 928;
    $args->{currency}        = 'JPY';
    $args->{action_type}     = 'buy';
    my $pricing_parameters = BOM::JapanContractDetails::verify_with_shortcode($args);
    $pricing_parameters = BOM::JapanContractDetails::include_contract_details(
        $pricing_parameters,
        {
            order_type  => 'buy',
            order_price => 928
        });
    my @expected_key = sort keys %{$expected_parameters};
    my @actual_key   = sort keys %{$pricing_parameters};
    cmp_deeply(\@expected_key, \@actual_key, 'Getting expected pricing parameters');

    my $ask_prob;
    foreach my $key (sort keys %{$pricing_parameters->{ask_probability}}) {
        $ask_prob += $pricing_parameters->{ask_probability}->{$key};
    }

    is(roundnear(1, $ask_prob * 1000), 950, 'Ask price is matching');
    foreach my $key (sort keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }
    }

};

subtest 'verify_with_shortcode_VV' => sub {
    my $expected_parameters = {
        'opposite_contract' => {
            'opposite_contract_Bet_vanna'                     => '-9.91592497397537',
            'opposite_contract_Bet_vega'                      => '-3.50117047823241',
            'opposite_contract_bet_vega'                      => '3.50117047823241',
            'opposite_contract_spot_spread_markup'            => '0.01',
            'opposite_contract_t'                             => '0.0321427891933029',
            'opposite_contract_discount_rate'                 => '0.026681002490942',
            'opposite_contract_vol'                           => '0.0693633014326143',
            'opposite_contract_vol_spread'                    => '0.00762335193452381',
            'opposite_contract_commission_multiplier'         => '1',
            'opposite_contract_Bet_volga'                     => '95.7847462902787',
            'opposite_contract_butterfly_greater_than_cutoff' => 0,
            'opposite_contract_bet_delta'                     => '0.759897820021909',
            'opposite_contract_risk_markup'                   => '0.0183453273691654',
            'opposite_contract_bs_probability'                => '0.249332690423872',
            'opposite_contract_vanna_market_price'            => '0.00358476433114927',
            'opposite_contract_volga_survival_weight'         => '0.338682379324212',
            'opposite_contract_commission_markup'             => '0.005',
            'opposite_contract_vega_survival_weight'          => '0.338682379324212',
            'opposite_contract_market_supplement'             => '0.00832877268009647',
            'opposite_contract_vega_market_price'             => '4.08641101380902e-17',
            'opposite_contract_vol_spread_markup'             => '0.0266906547383307',
            'opposite_contract_volga_market_price'            => '0.000412152893321488',
            'opposite_contract_vanna_correction'              => '-0.00504171685181347',
            'opposite_contract_butterfly_markup'              => 0,
            'opposite_contract_mu'                            => 0,
            'opposite_contract_vega_correction'               => '-4.84560385418264e-17',
            'opposite_contract_volga_correction'              => '0.01337048953191',
            'opposite_contract_payout'                        => '1000',
            'opposite_contract_S'                             => '79.817',
            'opposite_contract_vanna_survival_weight'         => '0.141835390855445',
            'opposite_contract_spot_spread'                   => '0.025',
            'opposite_contract_base_commission'               => '0.005',
            'opposite_contract_K'                             => '79.500',
            'opposite_contract_spread_to_markup'              => 2,
            'opposite_contract_theoretical_probability'       => '0.257661463103968'
        },
        'market_supplement' => {
            'volga_survival_weight' => '0.338609565227374',
            'Bet_vanna'             => '9.92290408928871',
            'vega_market_price'     => '4.08641101380902e-17',
            'Bet_volga'             => '-95.8758208135244',
            'vega_survival_weight'  => '0.338609565227374',
            'Bet_vega'              => '3.50527902626613',
            'volga_market_price'    => '0.000412152893321488',
            'vanna_correction'      => '0.00503576836121955',
            'vanna_survival_weight' => '0.141568405833703',
            'vega_correction'       => '4.85024707587182e-17',
            'vanna_market_price'    => '0.00358476433114927',
            'volga_correction'      => '-0.0133803252412607'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.741966313880216',
            'risk_markup'             => '0.0183609878229658',
            'commission_markup'       => '0.005'
        },
        'theoretical_probability' => {
            'bs_probability'    => '0.750310870760257',
            'market_supplement' => '-0.00834455688004112'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.0693633014326143',
            'K'             => '79.500',
            'mu'            => 0,
            'discount_rate' => '0.026681002490942',
            't'             => '0.0321427891933029',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'butterfly_greater_than_cutoff' => 0,
            'spot_spread_markup'            => '0.01',
            'bet_vega'                      => '3.50527902626613',
            'vol_spread'                    => '0.00762335193452381',
            'butterfly_markup'              => 0,
            'vol_spread_markup'             => '0.0267219756459316',
            'spread_to_markup'              => 2,
            'spot_spread'                   => '0.025',
            'bet_delta'                     => '0.760791904229521'
        },
        'commission_markup' => {
            'base_commission'       => '0.005',
            'commission_multiplier' => '1'
        },
        'contract_details' => {
            'ref_spot'               => 'NA',
            'ref_vol2'               => 'NA',
            'order_type'             => 'buy',
            'ref_vol'                => 'NA',
            'trade_bid_price'        => 'NA',
            'loginID'                => 'NA',
            'tick_before_trade_time' => '79.817',
            'short_code'             => 'ONETOUCH_FRXUSDJPY_1000_1352345145_1353358800_79500000_0',
            'ccy'                    => 'JPY',
            'description'            => 'Win payout if USD/JPY touches 79.500 through 2012-11-19 21:00:00 GMT.',
            'trans_id'               => 'NA',
            'order_price'            => 861,
            'trade_time'             => '2012-11-08 03:25:45',
            'slippage_price'         => 'NA',
            'trade_ask_price'        => 'NA',
            'payout'                 => '1000'
        }};

    my $args;
    $args->{landing_company} = 'japan';
    $args->{shortcode}       = 'ONETOUCH_FRXUSDJPY_1000_1352345145_1353358800_79500000_0';
    $args->{contract_price}  = 861;
    $args->{currency}        = 'JPY';
    $args->{action_type}     = 'buy';
    my $pricing_parameters = BOM::JapanContractDetails::verify_with_shortcode($args);
    $pricing_parameters = BOM::JapanContractDetails::include_contract_details(
        $pricing_parameters,
        {
            order_type  => 'buy',
            order_price => 861
        });

    my @expected_key = sort keys %{$expected_parameters};
    my @actual_key   = sort keys %{$pricing_parameters};
    cmp_deeply(\@expected_key, \@actual_key, 'Getting expected pricing parameters');

    my $ask_prob;
    foreach my $key (sort keys %{$pricing_parameters->{ask_probability}}) {
        $ask_prob += $pricing_parameters->{ask_probability}->{$key};
    }

    is(roundnear(1, $ask_prob * 1000), 765, 'Ask price is matching');
    foreach my $key (sort keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }

    }
};

prepare_market_data(Date::Utility->new(1491448384));

subtest '2017_with_extra_data' => sub {
    subtest 'verify_with_shortcode_IH' => sub {
        my $input = {
            shortcode       => 'CALLE_FRXUSDJPY_1000_1491448384_1491523199F_110146000_0',
            ask_price       => 798,
            bid_price       => 695,
            currency        => 'JPY',
            extra           => '110.500_0.0889897947653115_0.0928825867781793_0.0855312039590466_0.577290650270668',
            landing_company => 'japan',
        };

        my $output = BOM::JapanContractDetails::verify_with_shortcode($input);
        my $ask    = $output->{ask_probability};

        is $ask->{bs_probability},            0.76978238455266,    'matched bs probability';
        is $ask->{commission_markup},         0.005,               'matched commission markup';
        is $ask->{intraday_delta_correction}, 0,                   'matched intraday delta correction';
        is $ask->{intraday_vega_correction},  -0.0216800649832659, 'matched intraday vega correction';
        is $ask->{risk_markup},               0.0523059292012175,  'matched risk markup';
    };

    subtest 'verify_with_shortcode_Slope' => sub {
        my $input = {
            shortcode       => 'EXPIRYMISS_FRXUSDJPY_1000_1491448384_1491598800F_112917000_111836000',
            ask_price       => 951,
            bid_price       => 888,
            landing_company => 'japan',
            currency        => 'JPY',
            extra           => '110.500_0.135916237059658_0.133846265459211',
        };

        my $output = BOM::JapanContractDetails::verify_with_shortcode($input);
        is $output->{put_bs_probability}->{put_vol},   0.133846265459211;
        is $output->{call_bs_probability}->{call_vol}, 0.135916237059658;
    };

    subtest 'verify_with_shortcode_VV' => sub {
        my $input = {
            shortcode       => 'UPORDOWN_FRXUSDJPY_1000_1491473229_1514570400F_97947000_70407000',
            ask_price       => 296,
            bid_price       => 232,
            landing_company => 'japan',
            currency        => 'JPY',
            extra           => '83.769_0.119638984890473',
        };

        my $output = BOM::JapanContractDetails::verify_with_shortcode($input);
        is $output->{ask_probability}->{risk_markup},               0.00932737967138138, 'matched risk markup';
        is $output->{theoretical_probability}->{bs_probability},    0.212226990932264,   'matched bs probability';
        is $output->{theoretical_probability}->{market_supplement}, 0.0488884919520667,  'matched market supplement';
        is $output->{bs_probability}->{vol},                        0.119638984890473,   'matched vol';
    };
};

done_testing;

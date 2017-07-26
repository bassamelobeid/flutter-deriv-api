#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use Test::FailWarnings;
use Date::Utility;
use LandingCompany::Offerings qw(reinitialise_offerings);
use Test::MockModule;
use Math::Util::CalculatedValue::Validatable;

use BOM::Pricing::JapanContractDetails;
use BOM::MarketData qw(create_underlying);
use BOM::Market::DataDecimate;
use BOM::Platform::RedisReplicated;
use Data::Decimate qw(decimate);

use lib qw(/home/git/regentmarkets/bom-backoffice);
use BOM::Backoffice::Request;
use BOM::Backoffice::Sysinit ();

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Format::Util::Numbers qw(roundcommon);
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

    Volatility::Seasonality::generate_economic_event_seasonality({
        chronicle_writer   => BOM::Platform::Chronicle::get_chronicle_writer,
        underlying_symbols => [$underlying->symbol],
        economic_events    => $news->{$date->epoch},
        date               => $date,
    });
}
prepare_market_data($now);

subtest 'verify_with_shortcode_IH' => sub {
    my $expected_parameters = {
        'intraday_vega_correction' => {
            'intraday_vega'                 => '0.00539175374031617',
            'historical_vol_mean_reversion' => '0.10',
            'long_term_prediction'          => '0.1'
        },
        'opposite_contract' => {
            'opposite_contract_intraday_eod_markup'                    => 0,
            'opposite_contract_vol_spread_markup'                      => '0.212508872250682',
            'opposite_contract_long_term_prediction'                   => '0.1',
            'opposite_contract_t'                                      => '2.85388127853881e-05',
            'opposite_contract_intraday_historical_iv_risk'            => 0,
            'opposite_contract_short_term_kurtosis_risk_markup'        => 0,
            'opposite_contract_intraday_delta_correction'              => '-0.00689128727051409',
            'opposite_contract_intraday_vega'                          => '-0.00539175374031617',
            'opposite_contract_discount_rate'                          => 0,
            'opposite_contract_vol'                                    => '0.659269959705979',
            'opposite_contract_mu'                                     => 0,
            'opposite_contract_short_term_delta_correction'            => '-0.0131432219167099',
            'opposite_contract_commission_multiplier'                  => '1',
            'opposite_contract_payout'                                 => '1000',
            'opposite_contract_intraday_vega_correction'               => '-5.39175374031617e-05',
            'opposite_contract_quiet_period_markup'                    => 0,
            'opposite_contract_economic_events_markup'                 => 0.01,
            'opposite_contract_economic_events_volatility_risk_markup' => 0,
            'opposite_contract_economic_events_spot_risk_markup'       => 0.01,
            'opposite_contract_historical_vol_markup'                  => 0,
            'opposite_contract_S'                                      => '79.817',
            'opposite_contract_bs_probability'                         => '0.504959816692975',
            'opposite_contract_risk_markup'                            => '0.222508872250682',
            'opposite_contract_long_term_delta_correction'             => '-0.000639352624318246',
            'opposite_contract_historical_vol_mean_reversion'          => '0.10',
            'opposite_contract_base_commission'                        => '0.035',
            'opposite_contract_commission_markup'                      => '0.035',
            'opposite_contract_K'                                      => '79.820'
        },
        'ask_probability' => {
            'intraday_vega_correction'  => '5.39175374031617e-05',
            'risk_markup'               => '0.01',
            'bs_probability'            => '0.495040183307025',
            'intraday_delta_correction' => '0.00689128727051412',
            'commission_markup'         => '0.035'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.659269959705979',
            'K'             => '79.820',
            'mu'            => 0,
            'discount_rate' => 0,
            't'             => '2.85388127853881e-05',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'quiet_period_markup'                    => 0,
            'short_term_kurtosis_risk_markup'        => 0,
            'vol_spread_markup'                      => 0,
            'intraday_eod_markup'                    => 0,
            'economic_events_markup'                 => 0.01,
            'economic_events_spot_risk_markup'       => 0.01,
            'economic_events_volatility_risk_markup' => 0,
            'intraday_historical_iv_risk'            => 0,
            'historical_vol_markup'                  => 0,
        },
        'intraday_delta_correction' => {
            'short_term_delta_correction' => '0.0131432219167099',
            'long_term_delta_correction'  => '0.000639352624318301'
        },
        'commission_markup' => {
            'base_commission'       => '0.035',
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
    my $pricing_parameters = BOM::Pricing::JapanContractDetails::verify_with_shortcode($args);
    $pricing_parameters = BOM::Pricing::JapanContractDetails::include_contract_details(
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

    is(roundcommon(1, $ask_prob * 1000), 547, 'Ask price is matching');

    check_pricing_parameters($pricing_parameters, $expected_parameters);
};

subtest 'verify_with_shortcode_Slope' => sub {
    my $expected_parameters = {
        'risk_markup' => {
            'spot_spread_markup' => '0.00308207768049775',
            'vol_spread_markup'  => '0.0208358893418245'
        },
        'bs_probability' => {
            'call_payout'        => '1000',
            'call_vol'           => '0.0726586124131125',
            'call_S'             => '79.817',
            'call_discount_rate' => '0.0266870816706373',
            'call_t'             => '0.0321427891933029',
            'call_mu'            => 0,
            'call_K'             => '78.300'
        },
        'opposite_contract' => {
            'opposite_contract_put_K'                   => '78.300',
            'opposite_contract_vol_spread_markup'       => '0.0208358893418245',
            'opposite_contract_spot_spread_markup'      => '0.00308207768049775',
            'opposite_contract_put_mu'                  => 0,
            'opposite_contract_put_vol'                 => '0.0726586124131125',
            'opposite_contract_put_payout'              => '1000',
            'opposite_contract_commission_multiplier'   => '1',
            'opposite_contract_put_vanilla_vega'        => '1.90900653558009',
            'opposite_contract_put_slope'               => '-0.00260796496140414',
            'opposite_contract_put_S'                   => '79.817',
            'opposite_contract_put_discount_rate'       => '0.0266870816706373',
            'opposite_contract_risk_markup'             => '0.0119589835111611',
            'opposite_contract_put_weight'              => 1,
            'opposite_contract_base_commission'         => '0.035',
            'opposite_contract_commission_markup'       => '0.035',
            'opposite_contract_put_t'                   => '0.0321427891933029',
            'opposite_contract_theoretical_probability' => '0.06620951544713'
        },
        'commission_markup' => {
            'base_commission'       => '0.035',
            'commission_multiplier' => '1'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.932933055115425',
            'risk_markup'             => '0.0119589835111611',
            'commission_markup'       => '0.035'
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
            'call_slope'        => '-0.00260796496140414',
            'call_vanilla_vega' => '1.90900653558009',
        }};
    my $args;
    $args->{landing_company} = 'japan';
    $args->{shortcode}       = 'CALLE_FRXUSDJPY_1000_1352345145_1353358800_78300000_0';
    $args->{contract_price}  = 928;
    $args->{currency}        = 'JPY';
    $args->{action_type}     = 'buy';
    my $pricing_parameters = BOM::Pricing::JapanContractDetails::verify_with_shortcode($args);
    $pricing_parameters = BOM::Pricing::JapanContractDetails::include_contract_details(
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

    is(roundcommon(1, $ask_prob * 1000), 980, 'Ask price is matching');

    check_pricing_parameters($pricing_parameters, $expected_parameters);
};

subtest 'verify_with_shortcode_VV' => sub {
    my $expected_parameters = {
        'opposite_contract' => {
            'opposite_contract_Bet_vanna'                     => '-9.91592303638606',
            'opposite_contract_Bet_vega'                      => '-3.5011697940975',
            'opposite_contract_bet_vega'                      => '3.5011697940975',
            'opposite_contract_spot_spread_markup'            => '0.01',
            'opposite_contract_t'                             => '0.0321427891933029',
            'opposite_contract_discount_rate'                 => '0.0266870816706373',
            'opposite_contract_vol'                           => '0.0693633014326143',
            'opposite_contract_vol_spread'                    => '0.00762335193452381',
            'opposite_contract_commission_multiplier'         => '1',
            'opposite_contract_Bet_volga'                     => '95.7847275737695',
            'opposite_contract_butterfly_greater_than_cutoff' => 0,
            'opposite_contract_bet_delta'                     => '0.759897671536528',
            'opposite_contract_risk_markup'                   => '0.0183453247614647',
            'opposite_contract_bs_probability'                => '0.249332641703822',
            'opposite_contract_vanna_market_price'            => '0.0035847651797732',
            'opposite_contract_volga_survival_weight'         => '0.338682380060081',
            'opposite_contract_commission_markup'             => '0.035',
            'opposite_contract_vega_survival_weight'          => '0.338682380060081',
            'opposite_contract_market_supplement'             => '0.00832877595422193',
            'opposite_contract_vega_market_price'             => '4.08641196158852e-17',
            'opposite_contract_vol_spread_markup'             => '0.0266906495229295',
            'opposite_contract_volga_market_price'            => '0.000412153083267772',
            'opposite_contract_vanna_correction'              => '-0.00504171715609255',
            'opposite_contract_mu'                            => 0,
            'opposite_contract_vega_correction'               => '-4.84560404173354e-17',
            'opposite_contract_volga_correction'              => '0.0133704931103145',
            'opposite_contract_payout'                        => '1000',
            'opposite_contract_S'                             => '79.817',
            'opposite_contract_vanna_survival_weight'         => '0.141835393553629',
            'opposite_contract_spot_spread'                   => '0.025',
            'opposite_contract_base_commission'               => '0.035',
            'opposite_contract_K'                             => '79.500',
            'opposite_contract_spread_to_markup'              => 2,
            'opposite_contract_theoretical_probability'       => '0.257661417658044'
        },
        'market_supplement' => {
            'volga_survival_weight' => '0.338609549367812',
            'Bet_vanna'             => '9.9229037409789',
            'vega_market_price'     => '4.08641196158852e-17',
            'Bet_volga'             => '-95.8758228387405',
            'vega_survival_weight'  => '0.338609549367812',
            'Bet_vega'              => '3.50527927788657',
            'volga_market_price'    => '0.000412153083267772',
            'vanna_correction'      => '0.00503576730804588',
            'vanna_survival_weight' => '0.141568347681978',
            'vega_correction'       => '4.85024832180536e-17',
            'vanna_market_price'    => '0.0035847651797732',
            'volga_correction'      => '-0.0133803310637045'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.741966274538437',
            'risk_markup'             => '0.0183609887820614',
            'commission_markup'       => '0.035'
        },
        'theoretical_probability' => {
            'bs_probability'    => '0.750310838294096',
            'market_supplement' => '-0.00834456375565855'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.0693633014326143',
            'K'             => '79.500',
            'mu'            => 0,
            'discount_rate' => '0.0266870816706373',
            't'             => '0.0321427891933029',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'butterfly_greater_than_cutoff' => 0,
            'spot_spread_markup'            => '0.01',
            'bet_vega'                      => '3.50527927788657',
            'vol_spread'                    => '0.00762335193452381',
            'vol_spread_markup'             => '0.0267219775641228',
            'spread_to_markup'              => 2,
            'spot_spread'                   => '0.025',
            'bet_delta'                     => '0.760791959379195'
        },
        'commission_markup' => {
            'base_commission'       => '0.035',
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
    my $pricing_parameters = BOM::Pricing::JapanContractDetails::verify_with_shortcode($args);
    $pricing_parameters = BOM::Pricing::JapanContractDetails::include_contract_details(
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

    is(roundcommon(1, $ask_prob * 1000), 795, 'Ask price is matching');

    check_pricing_parameters($pricing_parameters, $expected_parameters);
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

        my $mocked = Test::MockModule->new('BOM::Product::Pricing::Engine::Intraday::Forex');
        $mocked->mock(
            'historical_vol_markup',
            sub {
                return Math::Util::CalculatedValue::Validatable->new({
                    name        => 'historical_vol_markup',
                    set_by      => 'test',
                    base_amount => 0,
                    description => 'test'
                });
            });
        my $output = BOM::Pricing::JapanContractDetails::verify_with_shortcode($input);

        my $ask = $output->{ask_probability};

        is $ask->{bs_probability},            0.76978238455266,    'matched bs probability';
        is $ask->{commission_markup},         0.035,               'matched commission markup';
        is $ask->{intraday_delta_correction}, 0,                   'matched intraday delta correction';
        is $ask->{intraday_vega_correction},  -0.0235434604443186, 'matched intraday vega correction';
        is $ask->{risk_markup},               0.036859882954911,  'matched risk markup';
        $mocked->unmock_all();
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

        my $output = BOM::Pricing::JapanContractDetails::verify_with_shortcode($input);
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

        my $output = BOM::Pricing::JapanContractDetails::verify_with_shortcode($input);
        is $output->{ask_probability}->{risk_markup},               0.00932723081365649, 'matched risk markup';
        is $output->{theoretical_probability}->{bs_probability},    0.212223673281774,   'matched bs probability';
        is $output->{theoretical_probability}->{market_supplement}, 0.0488906560526587,  'matched market supplement';
        is $output->{bs_probability}->{vol},                        0.119638984890473,   'matched vol';
    };
};

sub check_pricing_parameters {
    my ($pricing_parameters, $expected_parameters) = @_;

    foreach my $key (sort keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {

            if ($sub_key eq 'description') {
                my $desc = BOM::Backoffice::Request::localize($pricing_parameters->{$key}->{$sub_key});
                is($desc, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");
            } else {
                is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");
            }
        }

    }

    return;
}

done_testing;

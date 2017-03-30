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

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom/t/data/feed/');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');

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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $underlying->symbol,
        recorded_date => $now,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for ('USD', 'JPY-USD', 'JPY');

subtest 'verify_with_shortcode_IH' => sub {
    my $expected_parameters = {
        'intraday_vega_correction' => {
            'intraday_vega'                 => '0.219097343563215',
            'historical_vol_mean_reversion' => '0.10',
            'long_term_prediction'          => '0.082433105038935'
        },
        'opposite_contract' => {
            'opposite_contract_intraday_eod_markup'                    => 0,
            'opposite_contract_vol_spread_markup'                      => '0.000160311775951805',
            'opposite_contract_long_term_prediction'                   => '0.082433105038935',
            'opposite_contract_t'                                      => '2.85388127853881e-05',
            'opposite_contract_intraday_historical_iv_risk'            => 0,
            'opposite_contract_short_term_kurtosis_risk_markup'        => 0,
            'opposite_contract_intraday_delta_correction'              => '-0.0084369723586354',
            'opposite_contract_intraday_vega'                          => '-0.219097343563215',
            'opposite_contract_discount_rate'                          => 0,
            'opposite_contract_vol'                                    => '0.11279981070503',
            'opposite_contract_mu'                                     => 0,
            'opposite_contract_short_term_delta_correction'            => '-0.0131432219167099',
            'opposite_contract_commission_multiplier'                  => '1',
            'opposite_contract_payout'                                 => '1000',
            'opposite_contract_intraday_vega_correction'               => '-0.00180608743356982',
            'opposite_contract_quiet_period_markup'                    => 0,
            'opposite_contract_economic_events_markup'                 => 0,
            'opposite_contract_economic_events_volatility_risk_markup' => 0,
            'opposite_contract_economic_events_spot_risk_markup'       => 0,
            'opposite_contract_S'                                      => '79.817',
            'opposite_contract_bs_probability'                         => '0.524986766914232',
            'opposite_contract_risk_markup'                            => '0.000160311775951805',
            'opposite_contract_long_term_delta_correction'             => '-0.00373072280056086',
            'opposite_contract_historical_vol_mean_reversion'          => '0.10',
            'opposite_contract_base_commission'                        => '0.005',
            'opposite_contract_commission_markup'                      => '0.005',
            'opposite_contract_K'                                      => '79.820'
        },
        'ask_probability' => {
            'intraday_vega_correction'  => '0.00180608743356982',
            'risk_markup'               => '0.000160311775951805',
            'bs_probability'            => '0.475013233085768',
            'intraday_delta_correction' => '0.00843697235863543',
            'commission_markup'         => '0.005'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.11279981070503',
            'K'             => '79.820',
            'mu'            => 0,
            'discount_rate' => 0,
            't'             => '2.85388127853881e-05',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'quiet_period_markup'                    => 0,
            'short_term_kurtosis_risk_markup'        => 0,
            'vol_spread_markup'                      => '0.000160311775951805',
            'intraday_eod_markup'                    => 0,
            'economic_events_markup'                 => 0,
            'economic_events_spot_risk_markup'       => 0,
            'economic_events_volatility_risk_markup' => 0,
            'intraday_historical_iv_risk'            => 0
        },
        'intraday_delta_correction' => {
            'short_term_delta_correction' => '0.0131432219167099',
            'long_term_delta_correction'  => '0.00373072280056091'
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

    is(roundnear(1, $ask_prob * 1000), 490, 'Ask price is matching');
    foreach my $key (keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }

    }

};
subtest 'verify_with_shortcode_Slope' => sub {
    my $expected_parameters = {
        'risk_markup' => {
            'spot_spread_markup' => '0.00365449190614722',
            'vol_spread_markup'  => '0.0153826819687733'
        },
        'bs_probability' => {
            'call_payout'        => '1000',
            'call_vol'           => '0.186198565753633',
            'call_S'             => '79.817',
            'call_discount_rate' => '0.026681002490942',
            'call_t'             => '0.0321427891933029',
            'call_mu'            => 0,
            'call_K'             => '78.300'
        },
        'opposite_contract' => {
            'opposite_contract_put_K'                   => '78.300',
            'opposite_contract_vol_spread_markup'       => '0.0153826819687733',
            'opposite_contract_spot_spread_markup'      => '0.00365449190614722',
            'opposite_contract_put_mu'                  => 0,
            'opposite_contract_put_vol'                 => '0.186198565753633',
            'opposite_contract_put_payout'              => '1000',
            'opposite_contract_commission_multiplier'   => '1',
            'opposite_contract_put_vanilla_vega'        => '4.78848352361592',
            'opposite_contract_put_slope'               => '-0.0354653590530635',
            'opposite_contract_put_S'                   => '79.817',
            'opposite_contract_put_discount_rate'       => '0.026681002490942',
            'opposite_contract_risk_markup'             => '0.00951858693746026',
            'opposite_contract_put_weight'              => 1,
            'opposite_contract_base_commission'         => '0.005',
            'opposite_contract_commission_markup'       => '0.005',
            'opposite_contract_put_t'                   => '0.0321427891933029',
            'opposite_contract_theoretical_probability' => '0.11830556976102'
        },
        'commission_markup' => {
            'base_commission'       => '0.005',
            'commission_multiplier' => '1'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.880837196035802',
            'risk_markup'             => '0.00951858693746026',
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
            'short_code'             => 'CALLE_FRXUSDJPY_1000_1352345145_1353358800_783000_0',
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
            'call_slope'        => '-0.0354653590530635',
            'call_vanilla_vega' => '4.78848352361592'
        }};
    my $args;
    $args->{landing_company} = 'japan';
    $args->{shortcode}       = 'CALLE_FRXUSDJPY_1000_1352345145_1353358800_783000_0';
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

    is(roundnear(1, $ask_prob * 1000), 895, 'Ask price is matching');
    foreach my $key (sort keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }
    }

};

subtest 'verify_with_shortcode_VV' => sub {
    my $expected_parameters = {
        'opposite_contract' => {
            'opposite_contract_Bet_vanna'                     => '-2.46082555658013',
            'opposite_contract_Bet_vega'                      => '-0.797941039837406',
            'opposite_contract_bet_vega'                      => '0.797941039837406',
            'opposite_contract_spot_spread_markup'            => '0.00917233737284516',
            'opposite_contract_t'                             => '0.0321427891933029',
            'opposite_contract_discount_rate'                 => '0.026681002490942',
            'opposite_contract_vol'                           => '0.148224332423695',
            'opposite_contract_vol_spread'                    => '0.01',
            'opposite_contract_commission_multiplier'         => '1',
            'opposite_contract_Bet_volga'                     => '10.6468963914845',
            'opposite_contract_butterfly_greater_than_cutoff' => 0,
            'opposite_contract_bet_delta'                     => '0.366893494913806',
            'opposite_contract_risk_markup'                   => '0.00857587388560961',
            'opposite_contract_bs_probability'                => '0.1171915519255',
            'opposite_contract_vanna_market_price'            => '-0.0565842930426572',
            'opposite_contract_volga_survival_weight'         => '0.326729513082293',
            'opposite_contract_commission_markup'             => '0.005',
            'opposite_contract_vega_survival_weight'          => '0.326729513082293',
            'opposite_contract_market_supplement'             => '0.0608524456041279',
            'opposite_contract_vega_market_price'             => '8.28195738122469e-17',
            'opposite_contract_vol_spread_markup'             => '0.00797941039837406',
            'opposite_contract_volga_market_price'            => '0.0135700087406865',
            'opposite_contract_vanna_correction'              => '0.0136470631324557',
            'opposite_contract_butterfly_markup'              => 0,
            'opposite_contract_mu'                            => 0,
            'opposite_contract_vega_correction'               => '-2.15919645838777e-17',
            'opposite_contract_volga_correction'              => '0.0472053824716722',
            'opposite_contract_payout'                        => '1000',
            'opposite_contract_S'                             => '79.817',
            'opposite_contract_vanna_survival_weight'         => '0.0980082146350731',
            'opposite_contract_spot_spread'                   => '0.025',
            'opposite_contract_base_commission'               => '0.005',
            'opposite_contract_K'                             => '79.500',
            'opposite_contract_spread_to_markup'              => 2,
            'opposite_contract_theoretical_probability'       => '0.178043997529628'
        },
        'market_supplement' => {
            'volga_survival_weight' => '0.326630460666369',
            'Bet_vanna'             => '2.46370208495897',
            'vega_market_price'     => '8.28195738122469e-17',
            'Bet_volga'             => '-10.6607397812386',
            'vega_survival_weight'  => '0.326630460666369',
            'Bet_vega'              => '0.799081482096222',
            'volga_market_price'    => '0.0135700087406865',
            'vanna_correction'      => '-0.0136123840933145',
            'vanna_survival_weight' => '0.0976450224433527',
            'vega_correction'       => '2.16162692460576e-17',
            'vanna_market_price'    => '-0.0565842930426572',
            'volga_correction'      => '-0.0472524306685137'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.82175855163256',
            'risk_markup'             => '0.00858817624180108',
            'commission_markup'       => '0.005'
        },
        'theoretical_probability' => {
            'bs_probability'    => '0.882623366394388',
            'market_supplement' => '-0.0608648147618282'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.148224332423695',
            'K'             => '79.500',
            'mu'            => 0,
            'discount_rate' => '0.026681002490942',
            't'             => '0.0321427891933029',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'butterfly_greater_than_cutoff' => 0,
            'spot_spread_markup'            => '0.00918553766263994',
            'bet_vega'                      => '0.799081482096222',
            'vol_spread'                    => '0.01',
            'butterfly_markup'              => 0,
            'vol_spread_markup'             => '0.00799081482096222',
            'spread_to_markup'              => 2,
            'spot_spread'                   => '0.025',
            'bet_delta'                     => '0.367421506505598'
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
            'short_code'             => 'ONETOUCH_FRXUSDJPY_1000_1352345145_1353358800_795000_0',
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
    $args->{shortcode}       = 'ONETOUCH_FRXUSDJPY_1000_1352345145_1353358800_795000_0';
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

    is(roundnear(1, $ask_prob * 1000), 835, 'Ask price is matching');
    foreach my $key (sort keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }

    }

};

done_testing;

#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use Test::FailWarnings;
use Date::Utility;
use BOM::JapanContractDetails;
use BOM::MarketData qw(create_underlying);
use BOM::Market::DataDecimate;
use BOM::System::RedisReplicated;
use Data::Decimate qw(decimate);

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Format::Util::Numbers qw(roundnear);

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
            'intraday_vega'                 => '0.223516163808827',
            'historical_vol_mean_reversion' => '0.10',
            'long_term_prediction'          => '0.0797330542931892'
        },
        'opposite_contract' => {
            'opposite_contract_intraday_eod_markup'                    => 0,
            'opposite_contract_vol_spread_markup'                      => '0.000143148712425076',
            'opposite_contract_long_term_prediction'                   => '0.0797330542931892',
            'opposite_contract_t'                                      => '2.85388127853881e-05',
            'opposite_contract_intraday_historical_iv_risk'            => 0,
            'opposite_contract_short_term_kurtosis_risk_markup'        => 0,
            'opposite_contract_intraday_delta_correction'              => '-0.00845557256594666',
            'opposite_contract_intraday_vega'                          => '-0.223516163808827',
            'opposite_contract_discount_rate'                          => 0,
            'opposite_contract_vol'                                    => '0.111682401463366',
            'opposite_contract_mu'                                     => 0,
            'opposite_contract_short_term_delta_correction'            => '-0.0131432219167099',
            'opposite_contract_commission_multiplier'                  => '1',
            'opposite_contract_payout'                                 => '1000',
            'opposite_contract_intraday_vega_correction'               => '-0.00178216264243746',
            'opposite_contract_quiet_period_markup'                    => 0,
            'opposite_contract_economic_events_markup'                 => 0,
            'opposite_contract_economic_events_volatility_risk_markup' => 0,
            'opposite_contract_economic_events_spot_risk_markup'       => 0,
            'opposite_contract_S'                                      => '79.817',
            'opposite_contract_bs_probability'                         => '0.525234044869198',
            'opposite_contract_risk_markup'                            => '0.000143148712425076',
            'opposite_contract_long_term_delta_correction'             => '-0.00376792321518338',
            'opposite_contract_historical_vol_mean_reversion'          => '0.10',
            'opposite_contract_base_commission'                        => '0.035',
            'opposite_contract_commission_markup'                      => '0.035',
            'opposite_contract_K'                                      => '79.820'
        },
        'ask_probability' => {
            'intraday_vega_correction'  => '0.00178216264243746',
            'risk_markup'               => '0.000143148712425076',
            'bs_probability'            => '0.474765955130802',
            'intraday_delta_correction' => '0.00845557256594663',
            'commission_markup'         => '0.035'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.111682401463366',
            'K'             => '79.820',
            'mu'            => 0,
            'discount_rate' => 0,
            't'             => '2.85388127853881e-05',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'quiet_period_markup'                    => 0,
            'short_term_kurtosis_risk_markup'        => 0,
            'vol_spread_markup'                      => '0.000143148712425076',
            'intraday_eod_markup'                    => 0,
            'economic_events_markup'                 => 0,
            'economic_events_spot_risk_markup'       => 0,
            'economic_events_volatility_risk_markup' => 0,
            'intraday_historical_iv_risk'            => 0
        },
        'intraday_delta_correction' => {
            'short_term_delta_correction' => '0.0131432219167099',
            'long_term_delta_correction'  => '0.00376792321518332'
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

    is(roundnear(1, $ask_prob * 1000), 520, 'Ask price is matching');
    foreach my $key (keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }

    }

};
subtest 'verify_with_shortcode_Slope' => sub {
    my $expected_parameters = {
        'risk_markup' => {
            'spot_spread_markup' => '0.00369459188290466',
            'vol_spread_markup'  => '0.0159065154273165'
        },
        'bs_probability' => {
            'call_payout'        => '1000',
            'call_vol'           => '0.183017179537637',
            'call_S'             => '79.817',
            'call_discount_rate' => '0.026681002490942',
            'call_t'             => '0.0321427891933029',
            'call_mu'            => 0,
            'call_K'             => '78.300'
        },
        'opposite_contract' => {
            'opposite_contract_put_K'                   => '78.300',
            'opposite_contract_vol_spread_markup'       => '0.0159065154273165',
            'opposite_contract_spot_spread_markup'      => '0.00369459188290466',
            'opposite_contract_put_mu'                  => 0,
            'opposite_contract_put_vol'                 => '0.183017179537637',
            'opposite_contract_put_payout'              => '1000',
            'opposite_contract_commission_multiplier'   => '1',
            'opposite_contract_put_vanilla_vega'        => '4.7608437173126',
            'opposite_contract_put_slope'               => '-0.035476945572932',
            'opposite_contract_put_S'                   => '79.817',
            'opposite_contract_put_discount_rate'       => '0.026681002490942',
            'opposite_contract_risk_markup'             => '0.00980055365511059',
            'opposite_contract_put_weight'              => 1,
            'opposite_contract_base_commission'         => '0.035',
            'opposite_contract_commission_markup'       => '0.035',
            'opposite_contract_put_t'                   => '0.0321427891933029',
            'opposite_contract_theoretical_probability' => '0.115735075476901'
        },
        'commission_markup' => {
            'base_commission'       => '0.035',
            'commission_multiplier' => '1'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.883407690319921',
            'risk_markup'             => '0.00980055365511059',
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
            'call_slope'        => '-0.035476945572932',
            'call_vanilla_vega' => '4.7608437173126'
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

    is(roundnear(1, $ask_prob * 1000), 928, 'Ask price is matching');
    foreach my $key (sort keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }
    }

};

subtest 'verify_with_shortcode_VV' => sub {
    my $expected_parameters = {
        'opposite_contract' => {
            'opposite_contract_Bet_vanna'                     => '-2.57452763548286',
            'opposite_contract_Bet_vega'                      => '-0.835726450794668',
            'opposite_contract_bet_vega'                      => '0.835726450794668',
            'opposite_contract_spot_spread_markup'            => '0.00938805867931159',
            'opposite_contract_t'                             => '0.0321427891933029',
            'opposite_contract_discount_rate'                 => '0.026681002490942',
            'opposite_contract_vol'                           => '0.144796162395145',
            'opposite_contract_vol_spread'                    => '0.01',
            'opposite_contract_commission_multiplier'         => '1',
            'opposite_contract_Bet_volga'                     => '11.4088285164954',
            'opposite_contract_butterfly_greater_than_cutoff' => 0,
            'opposite_contract_bet_delta'                     => '0.375522347172464',
            'opposite_contract_risk_markup'                   => '0.00887266159362913',
            'opposite_contract_bs_probability'                => '0.119991050812156',
            'opposite_contract_vanna_market_price'            => '-0.0535757052910485',
            'opposite_contract_volga_survival_weight'         => '0.165742268527768',
            'opposite_contract_commission_markup'             => '0.035',
            'opposite_contract_vega_survival_weight'          => '0.165742268527768',
            'opposite_contract_market_supplement'             => '0.0473693906298077',
            'opposite_contract_vega_market_price'             => '-1.48834633087687e-16',
            'opposite_contract_vol_spread_markup'             => '0.00835726450794668',
            'opposite_contract_volga_market_price'            => '0.0129609605409399',
            'opposite_contract_vanna_correction'              => '0.0228611847692117',
            'opposite_contract_butterfly_markup'              => 0,
            'opposite_contract_mu'                            => 0,
            'opposite_contract_vega_correction'               => '2.06158586451094e-17',
            'opposite_contract_volga_correction'              => '0.024508205860596',
            'opposite_contract_payout'                        => '1000',
            'opposite_contract_S'                             => '79.817',
            'opposite_contract_vanna_survival_weight'         => '0.165742268527768',
            'opposite_contract_spot_spread'                   => '0.025',
            'opposite_contract_base_commission'               => '0.035',
            'opposite_contract_K'                             => '79.500',
            'opposite_contract_spread_to_markup'              => 2,
            'opposite_contract_theoretical_probability'       => '0.167360441441963'
        },
        'market_supplement' => {
            'volga_survival_weight' => '0.159397025578246',
            'Bet_vanna'             => '2.57750866038111',
            'vega_market_price'     => '-1.48834633087687e-16',
            'Bet_volga'             => '-11.4235664112811',
            'vega_survival_weight'  => '0.159397025578246',
            'Bet_vega'              => '0.836915862648721',
            'volga_market_price'    => '0.0129609605409399',
            'vanna_correction'      => '-0.0220114292497825',
            'vanna_survival_weight' => '0.159397025578246',
            'vega_correction'       => '-1.98548227154916e-17',
            'vanna_market_price'    => '-0.0535757052910485',
            'volga_correction'      => '-0.023600386328796'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.834208059237055',
            'risk_markup'             => '0.00888533428347731',
            'commission_markup'       => '0.035'
        },
        'theoretical_probability' => {
            'bs_probability'    => '0.879819874815633',
            'market_supplement' => '-0.0456118155785784'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.144796162395145',
            'K'             => '79.500',
            'mu'            => 0,
            'discount_rate' => '0.026681002490942',
            't'             => '0.0321427891933029',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'butterfly_greater_than_cutoff' => 0,
            'spot_spread_markup'            => '0.00940150994046742',
            'bet_vega'                      => '0.836915862648721',
            'vol_spread'                    => '0.01',
            'butterfly_markup'              => 0,
            'vol_spread_markup'             => '0.00836915862648721',
            'spread_to_markup'              => 2,
            'spot_spread'                   => '0.025',
            'bet_delta'                     => '0.376060397618697'
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
            'short_code'             => 'ONETOUCH_FRXUSDJPY_1000_1352345145_1353358800_795000_0',
            'ccy'                    => 'JPY',
            'description'            => 'Win payout if USD/JPY touches 79.500 through 2012-11-19 21:00:00 GMT.',
            'trans_id'               => 'NA',
            'order_price'            => 878,
            'trade_time'             => '2012-11-08 03:25:45',
            'slippage_price'         => 'NA',
            'trade_ask_price'        => 'NA',
            'payout'                 => '1000'
        }};

    my $args;
    $args->{landing_company} = 'japan';
    $args->{shortcode}       = 'ONETOUCH_FRXUSDJPY_1000_1352345145_1353358800_795000_0';
    $args->{contract_price}  = 878;
    $args->{currency}        = 'JPY';
    $args->{action_type}     = 'buy';
    my $pricing_parameters = BOM::JapanContractDetails::verify_with_shortcode($args);
    $pricing_parameters = BOM::JapanContractDetails::include_contract_details(
        $pricing_parameters,
        {
            order_type  => 'buy',
            order_price => 878
        });

    my @expected_key = sort keys %{$expected_parameters};
    my @actual_key   = sort keys %{$pricing_parameters};
    cmp_deeply(\@expected_key, \@actual_key, 'Getting expected pricing parameters');

    my $ask_prob;
    foreach my $key (sort keys %{$pricing_parameters->{ask_probability}}) {
        $ask_prob += $pricing_parameters->{ask_probability}->{$key};
    }

    is(roundnear(1, $ask_prob * 1000), 878, 'Ask price is matching');
    foreach my $key (sort keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }

    }

};

done_testing;

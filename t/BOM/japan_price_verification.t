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
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::AggTicks;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

my $at = BOM::Market::AggTicks->new;
$at->flush;

BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom/t/data/feed/');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');

my $underlying = create_underlying('frxUSDJPY');
my $now        = Date::Utility->new(1352345145);

$at->fill_from_historical_feed({
    underlying   => $underlying,
    ending_epoch => $now->epoch,
    interval     => Time::Duration::Concise->new('interval' => '1h'),
});

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
            'intraday_vega'                 => '0.223923209094351',
            'historical_vol_mean_reversion' => '0.10',
            'long_term_prediction'          => '0.0797330542931892'
        },
        'opposite_contract' => {
            'opposite_contract_intraday_eod_markup'             => 0,
            'opposite_contract_vol_spread_markup'               => '0',
            'opposite_contract_long_term_prediction'            => '0.0797330542931892',
            'opposite_contract_t'                               => '2.85388127853881e-05',
            'opposite_contract_intraday_historical_iv_risk'     => 0,
            'opposite_contract_short_term_kurtosis_risk_markup' => 0,
            'opposite_contract_intraday_delta_correction'       => '-0.008495817668548',
            'opposite_contract_intraday_vega'                   => '-0.223923209094351',
            'opposite_contract_discount_rate'                   => 0,
            'opposite_contract_vol'                             => '0.111581127892088',
            'opposite_contract_mu'                              => 0,
            'opposite_contract_short_term_delta_correction'     => '-0.013202192712293',
            'opposite_contract_commission_multiplier'           => '1',
            'opposite_contract_payout'                          => '1000',
            'opposite_contract_intraday_vega_correction'        => '-0.0017854081388225',
            'opposite_contract_quiet_period_markup'             => 0,
            'opposite_contract_economic_events_markup'          => 0,
            'opposite_contract_S'                               => '79.817',
            'opposite_contract_bs_probability'                  => '0.525256701751486',
            'opposite_contract_risk_markup'                     => 0,
            'opposite_contract_long_term_delta_correction'      => '-0.00378944262480296',
            'opposite_contract_historical_vol_mean_reversion'   => '0.10',
            'opposite_contract_base_commission'                 => '0.035',
            'opposite_contract_commission_markup'               => '0.035',
            'opposite_contract_K'                               => '79.820'
        },
        'ask_probability' => {
            'intraday_vega_correction'  => '0.0017854081388225',
            'risk_markup'               => 0,
            'bs_probability'            => '0.474743298248514',
            'intraday_delta_correction' => '0.00849581766854803',
            'commission_markup'         => '0.035'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.111581127892088',
            'K'             => '79.820',
            'mu'            => 0,
            'discount_rate' => 0,
            't'             => '2.85388127853881e-05',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'quiet_period_markup'             => 0,
            'short_term_kurtosis_risk_markup' => 0,
            'vol_spread_markup'               => '0',
            'intraday_eod_markup'             => 0,
            'economic_events_markup'          => 0,
            'intraday_historical_iv_risk'     => 0
        },
        'intraday_delta_correction' => {
            'short_term_delta_correction' => '0.013202192712293',
            'long_term_delta_correction'  => '0.00378944262480302'
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

    my @expected_key = keys %{$expected_parameters};
    my @actual_key  = keys %{$pricing_parameters};
    cmp_deeply(\@expected_key, \@actual_key, 'Getting expected pricing parameters');

   foreach my $key ( keys %{$pricing_parameters}){
       foreach my $sub_key (keys %{$pricing_parameters->{$key}}){
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

       }


   }

};

done_testing;

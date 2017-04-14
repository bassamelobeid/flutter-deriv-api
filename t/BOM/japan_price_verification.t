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
BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom/t/data/feed/');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');
my $volsurfaces = LoadFile('/home/git/regentmarkets/bom-test/data/20121108_volsurfaces.yml');
my $news        = LoadFile('/home/git/regentmarkets/bom-test/data/20121108_news.yml');
my $holidays    = LoadFile('/home/git/regentmarkets/bom-test/data/20121108_holidays.yml');

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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {events => $news});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => Date::Utility->new(1352345145),
        calendar      => $holidays
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new(1352345145)->truncate_to_day(),
        surface       => $volsurfaces->{frxUSDJPY}->{surfaces}->{'New York 10:00'},
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for ('USD', 'JPY-USD', 'JPY');

Volatility::Seasonality->new(
    chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
    )->generate_economic_event_seasonality({
        underlying_symbol => $underlying->symbol,
        economic_events   => $news
    });

subtest 'verify_with_shortcode_IH' => sub {
    my $expected_parameters = {
        'intraday_vega_correction' => {
            'intraday_vega'                 => '0.717628280049709',
            'historical_vol_mean_reversion' => '0.10',
            'long_term_prediction'          => '0.0463660615615842'
        },
        'opposite_contract' => {
            'opposite_contract_intraday_eod_markup'                    => 0,
            'opposite_contract_vol_spread_markup'                      => '0',
            'opposite_contract_long_term_prediction'                   => '0.0463660615615843',
            'opposite_contract_t'                                      => '2.85388127853881e-05',
            'opposite_contract_intraday_historical_iv_risk'            => 0,
            'opposite_contract_short_term_kurtosis_risk_markup'        => 0,
            'opposite_contract_intraday_delta_correction'              => '-0.00993653292664089',
            'opposite_contract_intraday_vega'                          => '-0.717628280049709',
            'opposite_contract_discount_rate'                          => 0,
            'opposite_contract_vol'                                    => '0.0622939620125683',
            'opposite_contract_mu'                                     => 0,
            'opposite_contract_short_term_delta_correction'            => '-0.0131432219167099',
            'opposite_contract_commission_multiplier'                  => '1',
            'opposite_contract_payout'                                 => '1000',
            'opposite_contract_intraday_vega_correction'               => '-0.00332735970111187',
            'opposite_contract_quiet_period_markup'                    => 0,
            'opposite_contract_economic_events_markup'                 => '0.00266557952786228',
            'opposite_contract_economic_events_volatility_risk_markup' => '0.00266557952786228',
            'opposite_contract_economic_events_spot_risk_markup'       => 0,
            'opposite_contract_S'                                      => '79.817',
            'opposite_contract_bs_probability'                         => '0.545027515478579',
            'opposite_contract_risk_markup'                            => '0.00266557952786228',
            'opposite_contract_long_term_delta_correction'             => '-0.00672984393657183',
            'opposite_contract_historical_vol_mean_reversion'          => '0.10',
            'opposite_contract_base_commission'                        => '0.005',
            'opposite_contract_commission_markup'                      => '0.005',
            'opposite_contract_K'                                      => '79.820'
        },
        'ask_probability' => {
            'intraday_vega_correction'  => '0.00332735970111186',
            'risk_markup'               => '0',
            'bs_probability'            => '0.454972484521421',
            'intraday_delta_correction' => '0.00993653292664089',
            'commission_markup'         => '0.005'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.0622939620125683',
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
            'economic_events_markup'                 => 0,
            'economic_events_spot_risk_markup'       => 0,
            'economic_events_volatility_risk_markup' => 0,
            'intraday_historical_iv_risk'            => 0
        },
        'intraday_delta_correction' => {
            'short_term_delta_correction' => '0.0131432219167099',
            'long_term_delta_correction'  => '0.00672984393657183'
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

    is(roundnear(1, $ask_prob * 1000), 473, 'Ask price is matching');
    foreach my $key (keys %{$pricing_parameters}) {
        foreach my $sub_key (keys %{$pricing_parameters->{$key}}) {
            is($pricing_parameters->{$key}->{$sub_key}, $expected_parameters->{$key}->{$sub_key}, "The $sub_key are matching");

        }

    }

};
subtest 'verify_with_shortcode_Slope' => sub {
    my $expected_parameters = {
        'risk_markup' => {
            'spot_spread_markup' => '0.00307069067224038',
            'vol_spread_markup'  => '0.0208139274321209'
        },
        'bs_probability' => {
            'call_payout'        => '1000',
            'call_vol'           => '0.0723844767710627',
            'call_S'             => '79.817',
            'call_discount_rate' => '0.026681002490942',
            'call_t'             => '0.0321427891933029',
            'call_mu'            => 0,
            'call_K'             => '78.300'
        },
        'opposite_contract' => {
            'opposite_contract_put_K'                   => '78.300',
            'opposite_contract_vol_spread_markup'       => '0.0208139274321209',
            'opposite_contract_spot_spread_markup'      => '0.00307069067224038',
            'opposite_contract_put_mu'                  => 0,
            'opposite_contract_put_vol'                 => '0.0723844767710627',
            'opposite_contract_put_payout'              => '1000',
            'opposite_contract_commission_multiplier'   => '1',
            'opposite_contract_put_vanilla_vega'        => '1.89335392836532',
            'opposite_contract_put_slope'               => '-0.00255458815729553',
            'opposite_contract_put_S'                   => '79.817',
            'opposite_contract_put_discount_rate'       => '0.026681002490942',
            'opposite_contract_risk_markup'             => '0.0119423090521807',
            'opposite_contract_put_weight'              => 1,
            'opposite_contract_base_commission'         => '0.005',
            'opposite_contract_commission_markup'       => '0.005',
            'opposite_contract_put_t'                   => '0.0321427891933029',
            'opposite_contract_theoretical_probability' => '0.0655925394874116'
        },
        'commission_markup' => {
            'base_commission'       => '0.005',
            'commission_multiplier' => '1'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.93355022630941',
            'risk_markup'             => '0.0119423090521807',
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
            'call_slope'        => '-0.00255458815729553',
            'call_vanilla_vega' => '1.89335392836532',
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
            'opposite_contract_Bet_vanna'                     => '-9.96018162731315',
            'opposite_contract_Bet_vega'                      => '-3.51894018871835',
            'opposite_contract_bet_vega'                      => '3.51894018871835',
            'opposite_contract_spot_spread_markup'            => '0.01',
            'opposite_contract_t'                             => '0.0321427891933029',
            'opposite_contract_discount_rate'                 => '0.026681002490942',
            'opposite_contract_vol'                           => '0.0691784734893044',
            'opposite_contract_vol_spread'                    => '0.00762335193452381',
            'opposite_contract_commission_multiplier'         => '1',
            'opposite_contract_Bet_volga'                     => '96.5002189489533',
            'opposite_contract_butterfly_greater_than_cutoff' => 0,
            'opposite_contract_bet_delta'                     => '0.761734645897951',
            'opposite_contract_risk_markup'                   => '0.0184130597475698',
            'opposite_contract_bs_probability'                => '0.249981444695272',
            'opposite_contract_vanna_market_price'            => '0.0035989235313351',
            'opposite_contract_volga_survival_weight'         => '0.338761923252651',
            'opposite_contract_commission_markup'             => '0.005',
            'opposite_contract_vega_survival_weight'          => '0.338761923252651',
            'opposite_contract_market_supplement'             => '0.00820985667978287',
            'opposite_contract_vega_market_price'             => '3.67835526075975e-19',
            'opposite_contract_vol_spread_markup'             => '0.0268261194951396',
            'opposite_contract_volga_market_price'            => '0.000406983457596874',
            'opposite_contract_vanna_correction'              => '-0.00509467664367527',
            'opposite_contract_butterfly_markup'              => 0,
            'opposite_contract_mu'                            => 0,
            'opposite_contract_vega_correction'               => '-4.38490457620074e-19',
            'opposite_contract_volga_correction'              => '0.0133045333234581',
            'opposite_contract_payout'                        => '1000',
            'opposite_contract_S'                             => '79.817',
            'opposite_contract_vanna_survival_weight'         => '0.142127051926388',
            'opposite_contract_spot_spread'                   => '0.025',
            'opposite_contract_base_commission'               => '0.005',
            'opposite_contract_K'                             => '79.500',
            'opposite_contract_spread_to_markup'              => 2,
            'opposite_contract_theoretical_probability'       => '0.258191301375055'
        },
        'market_supplement' => {
            'volga_survival_weight' => '0.33868921968087',
            'Bet_vanna'             => '9.96717114697775',
            'vega_market_price'     => '3.67835526075975e-19',
            'Bet_volga'             => '-96.5918281283282',
            'vega_survival_weight'  => '0.33868921968087',
            'Bet_vega'              => '3.52306561921917',
            'volga_market_price'    => '0.000406983457596874',
            'vanna_correction'      => '0.00508868930785907',
            'vanna_survival_weight' => '0.14186047216319',
            'vega_correction'       => '4.38910304838146e-19',
            'vanna_market_price'    => '0.0035989235313351',
            'volga_correction'      => '-0.0133143054565256'
        },
        'ask_probability' => {
            'theoretical_probability' => '0.741435739407054',
            'risk_markup'             => '0.0184287845518644',
            'commission_markup'       => '0.005'
        },
        'theoretical_probability' => {
            'bs_probability'    => '0.74966135555572',
            'market_supplement' => '-0.00822561614866658'
        },
        'bs_probability' => {
            'S'             => '79.817',
            'vol'           => '0.0691784734893044',
            'K'             => '79.500',
            'mu'            => 0,
            'discount_rate' => '0.026681002490942',
            't'             => '0.0321427891933029',
            'payout'        => '1000'
        },
        'risk_markup' => {
            'butterfly_greater_than_cutoff' => 0,
            'spot_spread_markup'            => '0.01',
            'bet_vega'                      => '3.52306561921917',
            'vol_spread'                    => '0.00762335193452381',
            'butterfly_markup'              => 0,
            'vol_spread_markup'             => '0.0268575691037288',
            'spread_to_markup'              => 2,
            'spot_spread'                   => '0.025',
            'bet_delta'                     => '0.762630021004011'
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

done_testing;

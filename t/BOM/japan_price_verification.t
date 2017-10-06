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

my $expected   = LoadFile('/home/git/regentmarkets/bom-backoffice/t/BOM/japan_price_verification_config.yml');
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
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            events        => $news->{$date->epoch},
            recorded_date => $date
        });
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
    my $expected_parameters = $expected->{intraday_historical};
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

    is(roundcommon(1, $ask_prob * 1000), 546, 'Ask price is matching');

    check_pricing_parameters($pricing_parameters, $expected_parameters);
};

subtest 'verify_with_shortcode_Slope' => sub {
    my $expected_parameters = $expected->{slope};
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
    my $expected_parameters = $expected->{vana_volga};
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
        is $ask->{risk_markup},               0.0581344778834122,  'matched risk markup';
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
        is $output->{ask_probability}->{risk_markup},               0.00932723065551091, 'matched risk markup';
        is $output->{theoretical_probability}->{bs_probability},    0.212223673281774,   'matched bs probability';
        is $output->{theoretical_probability}->{market_supplement}, 0.048890653424209,   'matched market supplement';
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

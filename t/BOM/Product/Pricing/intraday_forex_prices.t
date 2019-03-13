use strict;
use warnings;

use Data::Decimate qw(decimate);
use Date::Utility;
use File::Spec;
use Test::Most tests => 5;
use Test::Warnings;
use Volatility::EconomicEvents;
use YAML::XS qw(LoadFile);
use LandingCompany::Registry;
use Date::Utility;

use BOM::Market::DataDecimate;
use BOM::MarketData qw(create_underlying_db create_underlying);
use BOM::MarketData::Types;
use BOM::Config::Chronicle;
use BOM::Config::RedisReplicated;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Config::Runtime;
use Test::BOM::UnitTestPrice;

BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
    '{"yyy": {"market": "forex", "barrier_category": "euro_atm", "commission": "0.05", "name": "test commission", "updated_on": "xxx date", "updated_by": "xxyy"}}'
);
BOM::Config::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom-test/feed/combined');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('feed.ohlc_hourly',        'frxUSDJPY', '8-Nov-12');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('feed.ohlc_minutely_2012', 'frxUSDJPY', '8-Nov-12');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('feed.tick_2012_11',       'frxUSDJPY', '8-Nov-12');

my $volsurfaces = LoadFile('/home/git/regentmarkets/bom-test/data/20121108_volsurfaces.yml');
my $news        = LoadFile('/home/git/regentmarkets/bom-test/data/20121108_news.yml');
my $holidays    = LoadFile('/home/git/regentmarkets/bom-test/data/20121108_holidays.yml');

my $expected   = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/intraday_forex_config.yml');
my $date_start = Date::Utility->new(1352345145);
note('Pricing on ' . $date_start->datetime);
my $date_pricing    = $date_start;
my $date_expiry     = $date_start->plus_time_interval('1000s');
my $underlying      = create_underlying('frxUSDJPY', $date_pricing);
my $barrier         = 'S3P';
my $barrier_low     = 'S-3P';
my $payout          = 10000;
my $payout_currency = 'GBP';
my $duration        = 3600;

my $offerings_cfg = BOM::Config::Runtime->instance->get_offerings_config;

my $start = $date_start->epoch - 7200;
$start = $start - $start % 15;
my $first_agg = $start - 15;

my $hist_ticks = $underlying->ticks_in_between_start_end({
    start_time => $first_agg,
    end_time   => $date_start->epoch,
});

my @tmp_ticks = reverse @$hist_ticks;

my $decimate_cache = BOM::Market::DataDecimate->new({market => 'forex'});

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

my $recorded_date = $date_start->truncate_to_day;

Test::BOM::UnitTestPrice::create_pricing_data($underlying->symbol, $payout_currency, $recorded_date);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'JPY-USD',
        recorded_date => $date_pricing,
    });

my %equal = (
    CALLE => 1,
    PUTE  => 1,
);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events        => $news,
        recorded_date => $date_pricing
    });
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
        recorded_date => Date::Utility->new($volsurfaces->{frxUSDJPY}->{date}),
        surface       => $volsurfaces->{frxUSDJPY}->{surfaces}->{'New York 10:00'},
    });

my %skip_type = (
    LBFIXEDCALL => 1,
    LBFIXEDPUT  => 1,
    LBFLOATCALL => 1,
    LBFLOATPUT  => 1,
    LBHIGHLOW   => 1,
    CALLSPREAD  => 1,
    PUTSPREAD   => 1,
);

my @ct = grep { not $skip_type{$_} } grep { !$equal{$_} } LandingCompany::Registry::get('costarica')->basic_offerings($offerings_cfg)->query({
        underlying_symbol => $underlying->symbol,
        expiry_type       => 'intraday',
        start_type        => 'spot'
    },
    ['contract_type']);
my $vol = 0.15062438755219;
subtest 'prices without economic events' => sub {

    foreach my $contract_type (@ct) {
        my @barriers = @{
            Test::BOM::UnitTestPrice::get_barrier_range({
                    type       => 'single',
                    underlying => $underlying,
                    duration   => $duration,
                    spot       => $underlying->spot,
                    volatility => $vol,
                })};
        foreach my $barrier (@barriers) {
            lives_ok {
                my $c = produce_contract({
                    bet_type     => $contract_type,
                    underlying   => $underlying,
                    date_start   => $date_start,
                    date_pricing => $date_pricing,
                    duration     => $duration . 's',
                    currency     => $payout_currency,
                    payout       => $payout,
                    %$barrier,
                });
                my $key = $c->shortcode;
                my $exp = $expected->{$key};
                isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
                ok abs($c->ask_price - $exp->[0]) < 1e-9, 'correct ask price [' . $key . '] exp [' . $exp->[0] . '] got [' . $c->ask_price . ']';
                my $base = $c->pricing_engine->base_probability;
                ok abs($base->base_amount - $exp->[1]) < 1e-9,
                    'correct bs probability [' . $key . '] exp [' . $exp->[1] . '] got [' . $base->base_amount . ']';
                ok abs($c->pricing_engine->risk_markup->peek_amount('intraday_mean_reversion_markup') - $exp->[2]) < 1e-9,
                    'correct mean reversion markup [' . $key . '] exp [' . $exp->[2] . '] got [' . $c->pricing_engine->risk_markup->peek_amount('intraday_mean_reversion_markup') . ']';
                ok abs($base->peek_amount('intraday_vega_correction') - $exp->[3]) < 1e-9,
                    'correct vega correction [' . $key . '] exp [' . $exp->[3] . '] got [' . $base->peek_amount('intraday_vega_correction') . ']';
                ok abs($c->pricing_engine->risk_markup->amount - $exp->[4]) < 1e-9,
                    'correct risk markup [' . $key . '] exp [' . $exp->[4] . '] got [' . $c->pricing_engine->risk_markup->amount . ']';
            }
            'survived';
        }
    }
};

subtest 'atm prices without economic events' => sub {
    foreach my $contract_type (qw(CALL PUT)) {
        foreach my $duration (map { $_ * 60 } (3, 5, 10, 15)) {
            lives_ok {
                my $c = produce_contract({
                    bet_type     => $contract_type,
                    underlying   => $underlying,
                    date_start   => $date_start,
                    date_pricing => $date_pricing,
                    duration     => $duration . 's',
                    currency     => $payout_currency,
                    payout       => $payout,
                    barrier      => 'S0P',
                });
                my $key = $c->shortcode;
                my $exp = $expected->{$key};
                isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
                ok abs($c->ask_price - $exp->[0]) < 1e-9, 'correct ask price [' . $key . '] exp [' . $exp->[0] . '] got [' . $c->ask_price . ']';
                my $base = $c->pricing_engine->base_probability;
                ok abs($base->base_amount - $exp->[1]) < 1e-9,
                    'correct bs probability [' . $key . '] exp [' . $exp->[1] . '] got [' . $base->base_amount . ']';
                ok abs($c->pricing_engine->risk_markup->peek_amount('intraday_mean_reversion_markup') - $exp->[2]) < 1e-9,
                    'correct mean reversion markup [' . $key . '] exp [' . $exp->[2] . '] got [' . $c->pricing_engine->risk_markup->peek_amount('intraday_mean_reversion_markup') . ']';
                ok abs($base->peek_amount('intraday_vega_correction') - $exp->[3]) < 1e-9,
                    'correct vega correction [' . $key . '] exp [' . $exp->[3] . '] got [' . $base->peek_amount('intraday_vega_correction') . ']';
                ok abs($c->pricing_engine->risk_markup->amount - $exp->[4]) < 1e-9,
                    'correct risk markup [' . $key . '] exp [' . $exp->[4] . '] got [' . $c->pricing_engine->risk_markup->amount . ']';
            }
            'survived';
        }
    }
};

subtest 'prices with economic events' => sub {
    Volatility::EconomicEvents::generate_variance({
        underlying_symbols => [$underlying->symbol],
        economic_events    => $news,
        chronicle_writer   => BOM::Config::Chronicle::get_chronicle_writer,
        date               => $date_start,
    });

    foreach my $contract_type (@ct) {
        my @barriers = @{
            Test::BOM::UnitTestPrice::get_barrier_range({
                    type       => 'single',
                    underlying => $underlying,
                    duration   => $duration,
                    spot       => $underlying->spot,
                    volatility => $vol,
                })};
        foreach my $barrier (@barriers) {
            lives_ok {
                my $c = produce_contract({
                    bet_type     => $contract_type,
                    underlying   => $underlying,
                    date_start   => $date_start,
                    date_pricing => $date_pricing,
                    duration     => $duration . 's',
                    currency     => $payout_currency,
                    payout       => $payout,
                    %$barrier,
                });
                my $key = 'event_' . $c->shortcode;
                my $exp = $expected->{$key};
                isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
                ok abs($c->ask_price - $exp->[0]) < 1e-9, 'correct ask price [' . $key . '] exp [' . $exp->[0] . '] got [' . $c->ask_price . ']';
                my $base = $c->pricing_engine->base_probability;
                ok abs($base->base_amount - $exp->[1]) < 1e-9,
                    'correct bs probability [' . $key . '] exp [' . $exp->[1] . '] got [' . $base->base_amount . ']';
                ok abs($c->pricing_engine->risk_markup->peek_amount('intraday_mean_reversion_markup') - $exp->[2]) < 1e-9,
                    'correct mean reversion markup [' . $key . '] exp [' . $exp->[2] . '] got [' . $c->pricing_engine->risk_markup->peek_amount('intraday_mean_reversion_markup') . ']';
                ok abs($base->peek_amount('intraday_vega_correction') - $exp->[3]) < 1e-9,
                    'correct vega correction [' . $key . '] exp [' . $exp->[3] . '] got [' . $base->peek_amount('intraday_vega_correction') . ']';
                ok abs($c->pricing_engine->risk_markup->amount - $exp->[4]) < 1e-9,
                    'correct risk markup [' . $key . '] exp [' . $exp->[4] . '] got [' . $c->pricing_engine->risk_markup->amount . ']';
            }
            'survived';
        }
    }
};

subtest 'atm prices with economic events' => sub {
    foreach my $contract_type (qw(CALL PUT)) {
        foreach my $duration (map { $_ * 60 } (3, 5, 10, 15)) {
            lives_ok {
                my $c = produce_contract({
                    bet_type     => $contract_type,
                    underlying   => $underlying,
                    date_start   => $date_start,
                    date_pricing => $date_pricing,
                    duration     => $duration . 's',
                    currency     => $payout_currency,
                    payout       => $payout,
                    barrier      => 'S0P',
                });
                my $key = 'event_' . $c->shortcode;
                my $exp = $expected->{$key};
                isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
                ok abs($c->ask_price - $exp->[0]) < 1e-9, 'correct ask price [' . $key . '] exp [' . $exp->[0] . '] got [' . $c->ask_price . ']';
                my $base = $c->pricing_engine->base_probability;
                ok abs($base->base_amount - $exp->[1]) < 1e-9,
                    'correct bs probability [' . $key . '] exp [' . $exp->[1] . '] got [' . $base->base_amount . ']';
                ok abs($c->pricing_engine->risk_markup->peek_amount('intraday_mean_reversion_markup') - $exp->[2]) < 1e-9,
                    'correct mean reversion markup [' . $key . '] exp [' . $exp->[2] . '] got [' . $c->pricing_engine->risk_markup->peek_amount('intraday_mean_reversion_markup') . ']';
                ok abs($base->peek_amount('intraday_vega_correction') - $exp->[3]) < 1e-9,
                    'correct vega correction [' . $key . '] exp [' . $exp->[3] . '] got [' . $base->peek_amount('intraday_vega_correction') . ']';
                ok abs($c->pricing_engine->risk_markup->amount - $exp->[4]) < 1e-9,
                    'correct risk markup [' . $key . '] exp [' . $exp->[4] . '] got [' . $c->pricing_engine->risk_markup->amount . ']';
            }
            'survived';
        }
    }
};

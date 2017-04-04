use strict;
use warnings;

use Test::Most tests => 4;
use File::Spec;
use YAML::XS qw(LoadFile);
use LandingCompany::Offerings qw(get_offerings_with_filter);
use Date::Utility;
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Test::BOM::UnitTestPrice;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Volatility::Seasonality;
use BOM::Platform::Chronicle;

use BOM::Platform::RedisReplicated;
use BOM::Market::DataDecimate;
use Data::Decimate qw(decimate);

BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom/t/data/feed/');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');
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
my $payout          = 100;
my $payout_currency = 'GBP';
my $duration        = 3600;

my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;

my $start = $date_start->epoch - 7200;
$start = $start - $start % 15;
my $first_agg = $start - 15;

my $hist_ticks = $underlying->ticks_in_between_start_end({
    start_time => $first_agg,
    end_time   => $date_start->epoch,
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
my @ct = grep { !$equal{$_} } get_offerings_with_filter(
    $offerings_cfg,
    'contract_type',
    {
        underlying_symbol => $underlying->symbol,
        expiry_type       => 'intraday',
        start_type        => 'spot'
    });
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
                isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
                is $c->theo_probability->amount, $expected->{$c->shortcode}, 'correct ask probability [' . $c->shortcode . ']';
            }
            'survived';
        }
    }
};

subtest 'atm prices without economic events' => sub {
    foreach my $contract_type (qw(CALL PUT)) {
        foreach my $duration (map { $_ * 60 } (2, 5, 10, 15)) {
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
                isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
                is $c->theo_probability->amount, $expected->{$c->shortcode}, 'correct ask probability [event_' . $c->shortcode . ']';
            }
            'survived';
        }
    }
};

subtest 'prices with economic events' => sub {
    my $event_date = $date_start->minus_time_interval('15m');
    my $event      = [{
            symbol       => 'USD',
            impact       => 5,
            release_date => $event_date->epoch,
            event_name   => 'Construction Spending m/m'
        }];
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            recorded_date => $event_date,
            events        => $event,
        });
    Volatility::Seasonality->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
        )->generate_economic_event_seasonality({
            underlying_symbol => $underlying->symbol,
            economic_events   => $event
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
                isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
                is $c->theo_probability->amount, $expected->{'event_' . $c->shortcode}, 'correct ask probability [event_' . $c->shortcode . ']';
            }
            'survived';
        }
    }
};

subtest 'atm prices with economic events' => sub {
    foreach my $contract_type (qw(CALL PUT)) {
        foreach my $duration (map { $_ * 60 } (2, 5, 10, 15)) {
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
                isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
                is $c->theo_probability->amount, $expected->{'event_' . $c->shortcode}, 'correct ask probability [event_' . $c->shortcode . ']';
            }
            'survived';
        }
    }
};

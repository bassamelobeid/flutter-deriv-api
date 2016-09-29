use strict;
use warnings;

use Test::Most tests => 4;
use File::Spec;
use YAML::XS qw(LoadFile);
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Market::AggTicks;
use Date::Utility;
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::Test::Data::Utility::UnitTestPrice qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

my $at = BOM::Market::AggTicks->new;
$at->flush;

BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom/t/data/feed/');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');

my $expected   = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/intraday_forex_config.yml');
my $date_start = Date::Utility->new(1352345145);
note('Pricing on ' . $date_start->datetime);
my $date_pricing    = $date_start;
my $date_expiry     = $date_start->plus_time_interval('1000s');
my $underlying      = BOM::Market::Underlying->new('frxUSDJPY', $date_pricing);
my $barrier         = 'S3P';
my $barrier_low     = 'S-3P';
my $payout          = 100;
my $payout_currency = 'GBP';
my $duration        = 3600;

$at->fill_from_historical_feed({
    underlying   => $underlying,
    ending_epoch => $date_start->epoch,
    interval     => Time::Duration::Concise->new('interval' => '1h'),
});
my $recorded_date = $date_start->truncate_to_day;
BOM::Test::Data::Utility::UnitTestPrice::create_pricing_data($underlying->symbol, $payout_currency, $recorded_date);

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
my @ct = grep { !$equal{$_} } get_offerings_with_filter(
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
            BOM::Test::Data::Utility::UnitTestPrice::get_barrier_range({
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
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            recorded_date => $event_date,
            events        => [{
                    symbol       => 'USD',
                    impact       => 5,
                    release_date => $event_date->epoch,
                    event_name   => 'Construction Spending m/m'
                }]});
    foreach my $contract_type (@ct) {
        my @barriers = @{
            BOM::Test::Data::Utility::UnitTestPrice::get_barrier_range({
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

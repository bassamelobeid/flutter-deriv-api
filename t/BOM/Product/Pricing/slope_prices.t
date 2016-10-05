#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 660;
use Test::Exception;

use Format::Util::Numbers qw(roundnear);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Market::Underlying;
use Date::Utility;
use YAML::XS qw(LoadFile);
use Test::MockModule;

my $mocked = Test::MockModule->new('BOM::Product::Contract');
# Prices were originally built with only market volatility.
# Would like to keep it that way.
$mocked->mock('uses_empirical_volatility', sub {0});

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestPrice qw(:init);

my $now = Date::Utility->new('2016-02-01');
note('Pricing on ' . $now->datetime);

my %skip_category = (
    asian   => 1,
    digits  => 1,
    spreads => 1,
);

my $expectation        = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/slope_config.yml');
my @underlying_symbols = ('frxBROUSD', 'AEX', 'frxXAUUSD', 'RDBEAR', 'RDBULL', 'R_100', 'R_25', 'WLDEUR', 'frxEURSEK', 'frxUSDJPY');
my $payout_currency    = 'USD';
my $spot               = 100;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => $_,
        recorded_date => $now,
        rates         => {365 => 0},
    }) for qw(R_100 R_25);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'RDBULL',
        recorded_date => $now,
        rates         => {365 => -35},
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'RDBEAR',
        recorded_date => $now,
        rates         => {365 => 20},
    });

foreach my $ul (map { BOM::Market::Underlying->new($_) } @underlying_symbols) {
    BOM::Test::Data::Utility::UnitTestPrice::create_pricing_data($ul->symbol, $payout_currency, $now);
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $ul->symbol,
        quote      => $spot,
        epoch      => $now->epoch,
    });
    foreach my $contract_category (grep { not $skip_category{$_} } get_offerings_with_filter('contract_category', {underlying_symbol => $ul->symbol}))
    {
        my $category_obj = BOM::Product::Contract::Category->new($contract_category);
        next if $category_obj->is_path_dependent;
        my @duration = map { $_ * 86400 } (7, 14);
        foreach my $duration (@duration) {
            my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({
                underlying => $ul,
                for_date   => $now
            });
            my $vol = $volsurface->get_volatility({
                delta => 50,
                from  => $volsurface->recorded_date,
                to    => $volsurface->recorded_date->plus_time_interval($duration),
            });
            my @barriers = @{
                BOM::Test::Data::Utility::UnitTestPrice::get_barrier_range({
                        type => ($category_obj->two_barriers ? 'double' : 'single'),
                        underlying => $ul,
                        duration   => $duration,
                        spot       => $spot,
                        volatility => $vol,
                    })};

            @barriers = (
                {barrier => 'S0P'},
                {barrier => 'S100P'},
                {
                    high_barrier => '103',
                    low_barrier  => '94'
                }) if $ul->market->name eq 'volidx';

            foreach my $barrier (@barriers) {
                my %equal = (
                    CALLE        => 1,
                    PUTE         => 1,
                    EXPIRYMISSE  => 1,
                    EXPIRYRANGEE => 1,
                );
                foreach my $contract_type (grep { !$equal{$_} } get_offerings_with_filter('contract_type', {contract_category => $contract_category}))
                {
                    $duration /= 15 if $ul->market->name eq 'volidx';

                    my $args = {
                        bet_type     => $contract_type,
                        underlying   => $ul,
                        date_start   => $now,
                        date_pricing => $now,
                        duration     => $duration . 's',
                        currency     => $payout_currency,
                        payout       => 1000,
                        $ul->market->name eq 'volidx' ? (pricing_vol => 0.12) : (),
                        $ul->market->name eq 'volidx' ? (spot        => 100)  : (),
                        %$barrier,
                    };

                    lives_ok {
                        my $c = produce_contract($args);
                        my @codes = ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch);
                        if ($c->category->two_barriers) {
                            push @codes, ($c->high_barrier->as_absolute, $c->low_barrier->as_absolute);
                        } else {
                            push @codes, $c->barrier->as_absolute;
                        }
                        my $code = join '_', @codes;
                        isa_ok $c->pricing_engine, 'Pricing::Engine::EuropeanDigitalSlope';
                        is roundnear(0.00001, $c->theo_probability->amount), roundnear(0.00001, $expectation->{$code}),
                            'theo probability matches [' . $code . " - " . $c->shortcode . ']';
                    }
                    'survived';
                }
            }
        }
    }
}

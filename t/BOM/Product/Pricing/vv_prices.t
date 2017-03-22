#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 252;
use Test::Exception;

use Format::Util::Numbers qw(roundnear);
use BOM::Product::ContractFactory qw(produce_contract);
use LandingCompany::Offerings qw(get_offerings_with_filter);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::MarketData::Fetcher::VolSurface;
use Date::Utility;
use YAML::XS qw(LoadFile DumpFile);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Test::BOM::UnitTestPrice;
use LandingCompany::Offerings qw(reinitialise_offerings);

my $now = Date::Utility->new('2016-02-01');
note('Pricing on ' . $now->datetime);

my %skip_category = (
    asian   => 1,
    digits  => 1,
    spreads => 1,
);

my $expectation        = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/vv_config.yml');
my @underlying_symbols = ('frxBROUSD', 'AEX', 'frxXAUUSD', 'WLDEUR', 'frxEURSEK', 'frxUSDJPY');
my $payout_currency    = 'USD';
my $spot               = 100;
my $offerings_cfg      = BOM::Platform::Runtime->instance->get_offerings_config;

reinitialise_offerings($offerings_cfg);

foreach my $ul (map { create_underlying($_) } @underlying_symbols) {
    Test::BOM::UnitTestPrice::create_pricing_data($ul->symbol, $payout_currency, $now);
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $ul->symbol,
        quote      => $spot,
        epoch      => $now->epoch,
    });
    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({
        underlying => $ul,
        for_date   => $now
    });
    foreach my $contract_category (grep { not $skip_category{$_} }
        get_offerings_with_filter($offerings_cfg, 'contract_category', {underlying_symbol => $ul->symbol}))
    {
        my $category_obj = BOM::Product::Contract::Category->new($contract_category);
        next if not $category_obj->is_path_dependent;
        my @duration = map { $_ * 86400 } (7, 14);
        foreach my $duration (@duration) {
            my @barriers = @{
                Test::BOM::UnitTestPrice::get_barrier_range({
                        type => ($category_obj->two_barriers ? 'double' : 'single'),
                        underlying => $ul,
                        duration   => $duration,
                        spot       => $spot,
                        volatility => $volsurface->get_volatility({
                                delta => 50,
                                from  => $volsurface->recorded_date,
                                to    => $volsurface->recorded_date->plus_time_interval($duration),
                            }
                        ),
                    })};
            foreach my $barrier (@barriers) {
                foreach my $contract_type (get_offerings_with_filter($offerings_cfg, 'contract_type', {contract_category => $contract_category})) {
                    my $args = {
                        bet_type     => $contract_type,
                        underlying   => $ul,
                        date_start   => $now,
                        date_pricing => $now,
                        duration     => $duration . 's',
                        currency     => $payout_currency,
                        payout       => 1000,
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

                        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
                        is roundnear(0.00001, $c->theo_probability->amount), roundnear(0.00001, $expectation->{$code}),
                            'theo probability matches [' . $code . ']';
                    }
                    'survived';
                }
            }
        }
    }
}

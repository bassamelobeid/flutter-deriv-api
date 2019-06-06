#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 253;
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use YAML::XS qw(LoadFile DumpFile);
use Format::Util::Numbers qw/roundcommon/;

use LandingCompany::Registry;
use Test::BOM::UnitTestPrice;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

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
my $offerings_cfg      = BOM::Config::Runtime->instance->get_offerings_config;
my $offerings_obj      = LandingCompany::Registry::get('svg')->basic_offerings($offerings_cfg);

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
    foreach my $contract_category (grep { not $skip_category{$_} } $offerings_obj->query({underlying_symbol => $ul->symbol}, ['contract_category'])) {
        my $category_obj = Finance::Contract::Category->new($contract_category);
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
                                from  => $volsurface->creation_date,
                                to    => $volsurface->creation_date->plus_time_interval($duration),
                            }
                        ),
                    })};
            foreach my $barrier (@barriers) {
                foreach my $contract_type ($offerings_obj->query({contract_category => $contract_category}, ['contract_type'])) {
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

                    if (exists $args->{high_barrier} and exists $args->{low_barrier} and $args->{high_barrier} < $args->{low_barrier}) {
                        my ($h, $l) = ($args->{high_barrier}, $args->{low_barrier});
                        $args->{high_barrier} = $l;
                        $args->{low_barrier}  = $h;
                    }

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
                        is roundcommon(0.00001, $c->theo_probability->amount), roundcommon(0.00001, $expectation->{$code}),
                            'theo probability matches [' . $code . ']';
                    }
                    'survived';
                }
            }
        }
    }
}

#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;

use Format::Util::Numbers qw(roundnear);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::Runtime;
use LandingCompany::Registry;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;
use YAML::XS qw(LoadFile);
use Test::MockModule;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Test::BOM::UnitTestPrice;

my $offerings_cfg = BOM::Config::Runtime->instance->get_offerings_config;
my $now           = Date::Utility->new('2016-02-01');
note('Pricing on ' . $now->datetime);

my %skip_category = (
    callput      => 1,
    touchnotouch => 1,
    endsinout    => 1,
    staysinout   => 1,
    vanilla      => 1,
    asian        => 1,
    digits       => 1,
    spreads      => 1,
);

my $expectation        = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/lookback_config.yml');
my @underlying_symbols = ('R_100', 'R_75', 'R_50', 'R_25', 'R_10');
my $payout_currency    = 'USD';
my $spot               = 100;
my $offerings_obj      = LandingCompany::Registry::get('svg')->basic_offerings($offerings_cfg);

foreach my $ul (map { create_underlying($_) } @underlying_symbols) {
    Test::BOM::UnitTestPrice::create_pricing_data($ul->symbol, $payout_currency, $now);
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $ul->symbol,
        quote      => $spot,
        epoch      => $now->epoch,
    });

    my $offer_with_filter = $offerings_obj->query({underlying_symbol => $ul->symbol}, ['contract_category']);

    foreach my $contract_category (qw(lookback)) {
        my $category_obj = Finance::Contract::Category->new($contract_category);
        next if $category_obj->is_path_dependent;
        my @duration = map { $_ * 86400 } (7, 14);

        push @duration, 60;
        push @duration, 120;
        push @duration, 300;
        push @duration, 600;
        push @duration, 1200;
        push @duration, 3600;
        push @duration, 7200;
        push @duration, 18000;

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
                Test::BOM::UnitTestPrice::get_barrier_range({
                        type => ($category_obj->two_barriers ? 'double' : 'single'),
                        underlying => $ul,
                        duration   => $duration,
                        spot       => $spot,
                        volatility => $vol,
                    })};

            #we only price ATM contracts for financial instruments with flat vol-surface
            @barriers = ({barrier => 'S0P'}) if (($ul->symbol eq 'frxBROUSD' or $ul->symbol eq 'WLDEUR') and $ul->market->name ne 'synthetic_index');

            foreach my $barrier (@barriers) {
                my %equal = (
                    CALLE        => 1,
                    PUTE         => 1,
                    EXPIRYMISSE  => 1,
                    EXPIRYRANGEE => 1,
                );
                foreach my $contract_type (grep { !$equal{$_} } $offerings_obj->query({contract_category => $contract_category}, ['contract_type'])) {
                    my $args = {
                        bet_type     => $contract_type,
                        underlying   => $ul,
                        date_start   => $now,
                        date_pricing => $now,
                        duration     => $duration . 's',
                        currency     => $payout_currency,
                        multiplier       => $ul->symbol eq 'R_50' ? 5 : 1,
                    };

                    my $c = produce_contract($args);

                    isa_ok $c->pricing_engine_name, 'Pricing::Engine::Lookback';

                    is roundnear(0.00001, $c->theo_price), roundnear(0.00001, $expectation->{$c->shortcode}),
                        'theo price matches [' . $c->shortcode . ']';
                }
            }
        }
    }
}

done_testing;

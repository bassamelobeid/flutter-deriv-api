#!/etc/rmg/bin/perl

use strict;
use warnings;

# The cache causes our prices to vary slightly, so we disable for all QF modules.
BEGIN { $ENV{QUANT_FRAMEWORK_CACHE} = 0 }

use Test::More;
use Test::Exception;
use Date::Utility;
use YAML::XS qw(LoadFile);
use Test::MockModule;
use Format::Util::Numbers qw/roundcommon/;

use Test::BOM::UnitTestPrice;
use LandingCompany::Registry;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::Runtime;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

my $offerings_cfg = BOM::Config::Runtime->instance->get_offerings_config;
my $now           = Date::Utility->new('2016-02-01');
note('Pricing on ' . $now->datetime);

my %skip_category = (
    asian         => 1,
    digits        => 1,
    spreads       => 1,
    lookback      => 1,
    callputspread => 1,
);

my $expectation        = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/slope_config.yml');
my @underlying_symbols = ('frxBROUSD', 'AEX', 'frxXAUUSD', 'WLDEUR', 'frxEURSEK', 'frxUSDJPY');
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
    foreach my $contract_category (grep { not $skip_category{$_} } $offerings_obj->query({underlying_symbol => $ul->symbol}, ['contract_category'])) {
        my $category_obj = Finance::Contract::Category->new($contract_category);
        next if $category_obj->is_path_dependent;
        my @duration = map { $_ * 86400 } (7, 14);
        foreach my $duration (@duration) {
            my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({
                underlying => $ul,
                for_date   => $now
            });
            my $vol = $volsurface->get_volatility({
                delta => 50,
                from  => $volsurface->creation_date,
                to    => $volsurface->creation_date->plus_time_interval($duration),
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
                        isa_ok $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope';

                        ok abs($c->theo_probability->amount - $expectation->{$code}) < 1e-5,
                            'theo probability matches [' . $code . '] exp [' . $expectation->{$code} . '] got [' . $c->theo_probability->amount . ']';
                    }
                    'survived';
                }
            }
        }
    }
}

done_testing;

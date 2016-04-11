#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 877;
use Test::Exception;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Market::Underlying;
use Date::Utility;
use YAML::XS qw(LoadFile DumpFile);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestPrice qw(:init);

my $now = Date::Utility->new('2016-02-01');
note('Pricing on ' . $now->datetime);

my %skip_category = (
    asian   => 1,
    digits  => 1,
    spreads => 1,
);

my $expectation = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/slope_config.yml');
my @underlying_symbols =
    ('frxBROUSD', 'AEX', 'frxXAUUSD', 'RDBEAR', 'RDBULL', 'R_100', 'R_25', 'WLDEUR', 'frxEURSEK', 'frxUSDJPY');
my $payout_currency = 'USD';
my $spot            = 100;

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
            my $vol =
                $ul->volatility_surface_type eq 'phased'
                ? 0.1
                : BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $ul, for_date => $now})->get_volatility({
                    delta => 50,
                    days  => $duration / 86400
                });
            my @barriers = @{
                BOM::Test::Data::Utility::UnitTestPrice::get_barrier_range({
                        type => ($category_obj->two_barriers ? 'double' : 'single'),
                        underlying => $ul,
                        duration   => $duration,
                        spot       => $spot,
                        volatility => $vol,
                    })};
            foreach my $barrier (@barriers) {
                my %equal = (
                    CALLE        => 1,
                    PUTE         => 1,
                    EXPIRYMISSE  => 1,
                    EXPIRYRANGEE => 1,
                );
                foreach my $contract_type (grep { !$equal{$_} } get_offerings_with_filter('contract_type', {contract_category => $contract_category}))
                {
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
                        isa_ok $c->pricing_engine, 'Pricing::Engine::EuropeanDigitalSlope';
                        is $c->theo_probability->amount, $expectation->{$code}, 'theo probability matches [' . $c->shortcode . ']';
                    }
                    'survived';
                }
            }
        }
    }
}

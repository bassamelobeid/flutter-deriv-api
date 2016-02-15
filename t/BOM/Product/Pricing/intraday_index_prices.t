#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 21;
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

my $expectation = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/intraday_index_config.yml');
my @underlying_symbols = ('AEX');
my $payout_currency = 'USD';
my $spot            = 100;

foreach my $ul (map { BOM::Market::Underlying->new($_) } @underlying_symbols) {
    BOM::Test::Data::Utility::UnitTestPrice::create_pricing_data($ul->symbol, $payout_currency, $now);
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $ul->symbol,
        quote      => $spot,
        epoch      => $now->epoch,
    });
    foreach my $contract_category (grep { not $skip_category{$_} } get_offerings_with_filter('contract_category', {underlying_symbol => $ul->symbol, expiry_type => 'intraday', start_type => 'spot'})) {
        my $category_obj = BOM::Product::Contract::Category->new($contract_category);
        next if $category_obj->is_path_dependent;
        my @duration = map { $_ * 3600 } (1 .. 5);
        foreach my $duration (@duration) {
            my $vol = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $ul})->get_volatility({delta => 50, days => $duration / 24});
            foreach my $contract_type (get_offerings_with_filter('contract_type', {contract_category => $contract_category})) {
                my $args = {
                    bet_type     => $contract_type,
                    underlying   => $ul,
                    date_start   => $now,
                    date_pricing => $now,
                    duration     => $duration . 's',
                    currency     => $payout_currency,
                    payout       => 1000,
                    barrier      => 'S0P',
                };

                lives_ok {
                    my $c = produce_contract($args);
                    my @codes = ($c->code,$c->underlying->symbol,$c->date_start->epoch,$c->date_expiry->epoch);
                    if ($c->category->two_barriers) {
                        push @codes, ($c->high_barrier->as_absolute, $c->low_barrier->as_absolute);
                    } else {
                        push @codes, $c->barrier->as_absolute;
                    }
                    my $code = join '_', @codes;
                    is $c->theo_probability->amount, $expectation->{$code}, 'theo probability matches [' . $code . ']';
                } 'survived';
            }
        }
    }
}

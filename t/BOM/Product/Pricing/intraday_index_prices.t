#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 31;
use Test::Warnings;
use Test::Exception;

use BOM::Product::ContractFactory qw(produce_contract);
use LandingCompany::Registry;
use BOM::Config::Runtime;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;
use YAML::XS qw(LoadFile DumpFile);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Test::BOM::UnitTestPrice qw(:init);

my $now = Date::Utility->new('2016-02-01');
note('Pricing on ' . $now->datetime);

my $offerings_cfg = BOM::Config::Runtime->instance->get_offerings_config;
my %skip_category = (
    asian   => 1,
    digits  => 1,
    spreads => 1,
);

my $expectation        = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/intraday_index_config.yml');
my @underlying_symbols = ('AEX');
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
    foreach my $contract_category (
        grep { not $skip_category{$_} } $offerings_obj->query({
                underlying_symbol => $ul->symbol,
                expiry_type       => 'intraday',
                start_type        => 'spot'
            },
            ['contract_category']))
    {
        my $category_obj = Finance::Contract::Category->new($contract_category);
        next if $category_obj->is_path_dependent;
        my @duration = map { $_ * 60 } (15, 20, 25, 40, 60);
        foreach my $duration (@duration) {
            my %equal = (
                CALLE => 1,
                PUTE  => 1,
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
                    barrier      => 'S0P',
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
                    isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Index';
                    is $c->theo_probability->amount, $expectation->{$code}, 'theo probability matches [' . $code . ']';
                }
                'survived';
            }
        }
    }
}

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
use YAML::XS qw(LoadFile DumpFile);
use Test::MockModule;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Test::BOM::UnitTestPrice;

my $offerings_cfg = BOM::Config::Runtime->instance->get_offerings_config;
my $now           = Date::Utility->new('2016-02-01');
note('Pricing on ' . $now->datetime);

my %skip_category = (
    callput    => 1,
    endsinout  => 1,
    staysinout => 1,
    vanilla    => 1,
    asian      => 1,
    digits     => 1,
    spreads    => 1,
    reset      => 1,
    lookback   => 1,
);

my $expected_theo_price = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/tick_ot_nt.yml');
my @underlying_symbols  = ('R_100');
my $payout_currency     = 'USD';
my $spot                = 1000;
my $offerings_obj       = LandingCompany::Registry::get('svg')->basic_offerings($offerings_cfg);

foreach my $ul (map { create_underlying($_) } @underlying_symbols) {
    Test::BOM::UnitTestPrice::create_pricing_data($ul->symbol, $payout_currency, $now);
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $ul->symbol,
        quote      => $spot,
        epoch      => $now->epoch,
    });

    my $offer_with_filter = $offerings_obj->query({underlying_symbol => $ul->symbol}, ['contract_category']);

    foreach my $contract_category (qw(touchnotouch)) {
        my $category_obj = Finance::Contract::Category->new($contract_category);

        my @duration = map { $_ } (5, 6, 7, 8, 9, 10);
        foreach my $duration (@duration) {
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
                    duration     => $duration . 't',
                    currency     => $payout_currency,
                    amount       => 10,
                    amount_type  => 'payout',
                    barrier      => '+0.5',
                };

                my $c = produce_contract($args);

                isa_ok $c->pricing_engine_name, 'Pricing::Engine::BlackScholes';

                is roundnear(0.00001, $c->theo_price), roundnear(0.00001, $expected_theo_price->{$c->shortcode}),
                    'theo price matches [' . $c->shortcode . ']';

            }
        }
    }
}

done_testing;

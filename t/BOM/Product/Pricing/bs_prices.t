#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 217;
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use YAML::XS qw(LoadFile);
use Test::MockModule;
use Format::Util::Numbers qw/roundcommon/;
use LandingCompany::Registry;
use Test::BOM::UnitTestPrice;

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
    callputspread => 1,
);

my $expectation        = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/bs_config.yml');
my @underlying_symbols = ('RDBEAR', 'RDBULL', 'R_100', 'R_25');
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

foreach my $ul (map { create_underlying($_) } @underlying_symbols) {
    Test::BOM::UnitTestPrice::create_pricing_data($ul->symbol, $payout_currency, $now);
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $ul->symbol,
        quote      => $spot,
        epoch      => $now->epoch,
    });
    my $offerings_obj = LandingCompany::Registry::get('costarica')->basic_offerings($offerings_cfg);
    foreach my $contract_category (grep { not $skip_category{$_} } $offerings_obj->query({underlying_symbol => $ul->symbol}, ['contract_category'])) {
        my $category_obj = Finance::Contract::Category->new($contract_category);
        my @duration = map { $_ * 86400 } (7, 14);
        foreach my $duration (@duration) {
            my @barriers = (
                {barrier => 'S0P'},
                {barrier => 'S100P'},
                {
                    high_barrier => '103',
                    low_barrier  => '94'
                });

            foreach my $barrier (@barriers) {
                my %equal = (
                    CALLE        => 1,
                    PUTE         => 1,
                    EXPIRYMISSE  => 1,
                    EXPIRYRANGEE => 1,
                );
                foreach my $contract_type (grep { !$equal{$_} } $offerings_obj->query({contract_category => $contract_category}, ['contract_type'])) {
                    $duration /= 15;
                    next if $duration < 1;
                    my $args = {
                        bet_type     => $contract_type,
                        underlying   => $ul,
                        date_start   => $now,
                        date_pricing => $now,
                        duration     => $duration . 's',
                        currency     => $payout_currency,
                        payout       => 1000,
                        pricing_vol  => 0.12,
                        spot         => 100,
                        %$barrier,
                    };

                    #Go to the next contract, if current setting has one barrier and contract type needs two or vice versa
                    next if $contract_type =~ /^(EXPIRY|RANGE|UPORDOWN)/ and not exists $barrier->{high_barrier};
                    next if $contract_type !~ /^(EXPIRY|RANGE|UPORDOWN)/ and exists $barrier->{high_barrier};

                    next if $contract_type =~ /^(RESETCALL|RESETPUT|LBFLOATCALL|LBFLOATPUT|LBHIGHLOW|TICKHIGH|TICKLOW|RUNHIGH|RUNLOW)/;

                    lives_ok {
                        my $c = produce_contract($args);

                        my @codes = ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch);
                        if ($c->category->two_barriers) {
                            push @codes, ($c->high_barrier->as_absolute, $c->low_barrier->as_absolute);
                        } else {
                            push @codes, $c->barrier->as_absolute;
                        }
                        my $code = join '_', @codes;
                        isa_ok $c->pricing_engine_name, 'Pricing::Engine::BlackScholes';
                        is roundcommon(0.00001, $c->theo_probability->amount), roundcommon(0.00001, $expectation->{$code}),
                            'theo probability matches [' . $code . " - " . $c->shortcode . ']';
                    }
                    'survived';
                }
            }
        }
    }
}


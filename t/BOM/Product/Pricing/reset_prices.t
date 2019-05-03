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
    callput      => 1,
    touchnotouch => 1,
    endsinout    => 1,
    staysinout   => 1,
    vanilla      => 1,
    asian        => 1,
    digits       => 1,
    spreads      => 1,
    lookback     => 1,
);

my $expectation        = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/reset_config.yml');
my @underlying_symbols = ('R_100');
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

    foreach my $contract_category (qw(reset)) {
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

            foreach my $contract_type ($offerings_obj->query({contract_category => $contract_category}, ['contract_type'])) {
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

                my $c = produce_contract($args);
                isa_ok $c->pricing_engine_name, 'Pricing::Engine::Reset';

                my @codes = ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch);
                if ($c->category->two_barriers) {
                    push @codes, ($c->high_barrier->as_absolute, $c->low_barrier->as_absolute);
                } else {
                    push @codes, $c->barrier->as_absolute;
                }
                my $code = join '_', @codes;

                is roundnear(0.00001, $c->theo_price), roundnear(0.00001, $expectation->{$code}), 'theo price matches [' . $code . ']';
                $expectation->{$code} = $c->theo_price;
            }
        }
    }
}

subtest 'reset spot tests' => sub {
    my $now  = Date::Utility->new;
    my $args = {
        underlying => 'R_100',
        bet_type   => 'RESETCALL',
        date_start => $now,
        currency   => 'USD',
        payout     => 100,
        barrier    => 'S0P'
    };

    my @test_data = (
        [[(map { [$now->epoch + $_, 100] } (2, 4)), [$now->epoch + 6, 102]], '5t', 'reset on second tick'],
        [[(map { [$now->epoch + $_, 100] } (2, 4, 6)), [$now->epoch + 8, 102]], '6t', 'reset on third tick'],
        [[(map { [$now->epoch + $_, 100] } (2, 4, 6)), [$now->epoch + 8, 102]], '7t', 'reset on third tick'],
        [[(map { [$now->epoch + $_, 100] } (2, 4, 6, 8, 10)), [$now->epoch + 12, 102]], '10t', 'reset on fifth tick'],
    );
    foreach my $d (@test_data) {
        BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
        my $ticks        = $d->[0];
        my $duration     = $d->[1];
        my $test_comment = $d->[2];
        note($test_comment);
        my $date_pricing;
        foreach my $t (@$ticks) {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => $args->{underlying},
                epoch      => $t->[0],
                quote      => $t->[1],
            });
            $date_pricing = $t->[0];
        }
        $args->{date_pricing} = $date_pricing + 1;
        $args->{duration}     = $duration;
        my $c = produce_contract($args);
        is $c->reset_spot->quote, 102, $test_comment;
    }
};

done_testing;

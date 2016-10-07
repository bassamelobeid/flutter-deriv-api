#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;

use Format::Util::Numbers qw(roundnear);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Platform::Offerings qw(get_offerings_with_filter);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::MarketData::Fetcher::VolSurface;
use Date::Utility;
use YAML::XS qw(LoadFile DumpFile);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestPrice qw(:init);

my $expectation = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/sellback_config.yml');
my $start_time  = Date::Utility->new(1474860428);

# for my $code (keys $expectation) {
#     my ($shortcode, $mins_time_pricing) = split(/\|/, $code);

#     price_contract_at($shortcode, $mins_time_pricing, $expectation->{$code});
# }
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

for my $type (qw(CALL PUT)) {
    for my $underlying (qw(R_100 R_25 frxEURUSD frxUSDJPY AEX frxBROUSD WLDEUR)) {
        for my $duration (qw(2m 5m 10m 2h 6h)) {
            for my $back_time (qw(1m)) {
                my $expiry_time = $start_time->plus_time_interval($duration);
                my $times       = $start_time->epoch . '_' . $expiry_time->epoch;
                my $shortcode   = $type . '_' . $underlying . '_10_' . $times . '_S0P_0';
                my $code        = $shortcode . '|' . $back_time;

                note "checking price for $shortcode at $back_time before expiry...";

                ok defined $expectation->{$code}, "config file contains the required data";
                price_contract_at($type, $underlying, $duration, $back_time, $expectation->{$code});
            }
        }
    }
}

done_testing;

sub price_contract_at {
    my ($bet_type, $underlying, $duration, $price_back, $expected_price) = @_;

    my $date_pricing = $start_time->plus_time_interval($duration)->minus_time_interval($price_back);

    my $bet_params = {
        bet_type     => $bet_type,
        underlying   => $underlying,
        barrier      => 'S0P',
        payout       => 10,
        currency     => 'USD',
        duration     => $duration,
        date_start   => $start_time,
        date_pricing => $date_pricing,
    };

    BOM::Test::Data::Utility::UnitTestPrice::create_pricing_data($underlying, 'USD', $date_pricing);
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => 'EUR-USD',
            recorded_date => $date_pricing,
        });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $underlying,
            quote      => 100,
            epoch      => $date_pricing->epoch,
        }) if $bet_type eq 'CALL';

    my $c = produce_contract($bet_params);
    is roundnear(0.00001, $c->bid_price), roundnear(0.00001, $expected_price);
}


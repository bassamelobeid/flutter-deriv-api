#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Date::Utility;
use YAML::XS qw(LoadFile DumpFile);
use Format::Util::Numbers qw/roundcommon/;

use Test::BOM::UnitTestPrice qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Test::MockModule;

my $expectation = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/sellback_config.yml');
my $start_time  = Date::Utility->new(1474860428);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                event_name   => 'FOMC',
            }
        ],
        recorded_date => $start_time
    });

for my $type (qw(CALL PUT)) {
    for my $underlying (qw(R_100 R_25 OTC_AEX WLDEUR)) {
        for my $duration (qw(2m 5m 10m 2h 6h)) {
            for my $back_time (qw(1m)) {
                my $expiry_time = $start_time->plus_time_interval($duration);
                my $times       = $start_time->epoch . '_' . $expiry_time->epoch;
                my $shortcode   = $type . '_' . $underlying . '_10_' . $times . '_S0P_0';
                my $code        = $shortcode . '|' . $back_time;

                note "checking price for $shortcode at $back_time before expiry...";

                ok defined $expectation->{$code}, "config file contains the required data";
                price_contract_at($type, $underlying, $duration, $back_time, $expectation->{$code}, $code);
            }
        }
    }

    for my $underlying (qw(frxEURUSD frxUSDJPY frxBROUSD)) {
        for my $duration (qw(5m 10m 2h 6h)) {
            for my $back_time (qw(3m 1m)) {
                my $expiry_time = $start_time->plus_time_interval($duration);
                my $times       = $start_time->epoch . '_' . $expiry_time->epoch;
                my $shortcode   = $type . '_' . $underlying . '_10_' . $times . '_S0P_0';
                my $code        = $shortcode . '|' . $back_time;

                note "checking price for $shortcode at $back_time before expiry...";

                ok defined $expectation->{$code}, "config file contains the required data";
                price_contract_at($type, $underlying, $duration, $back_time, $expectation->{$code}, $code);
            }
        }
    }
}

done_testing;

sub price_contract_at {
    my ($bet_type, $underlying, $duration, $price_back, $expected_price, $code) = @_;

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
        pricing_vol  => 0.1
    };

    Test::BOM::UnitTestPrice::create_pricing_data($underlying, 'USD', $date_pricing);
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
    is roundcommon(0.00001, $c->bid_price), roundcommon(0.00001, $expected_price), $code;
}


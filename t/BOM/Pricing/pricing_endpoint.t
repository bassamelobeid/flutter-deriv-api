#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Most;
use Test::Mojo;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Pricing::v4::PricingEndpoint;
use Plack::Test;

my $now = Date::Utility->new();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'R_50',
        date   => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'R_50',
        recorded_date => $now
    });

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => $now->epoch,
    quote      => 100
});

my $tests = {
    "TICKHIGH_R_50_100_1619506193_5t_1"        => {theo_probability => 0.273},
    "DIGITMATCH_R_10_18.18_0_5T_7_0"           => {theo_probability => 0.1},
    "RUNHIGH_R_100_100.00_1619507455_3T_S0P_0" => {theo_probability => 0.125},
};

subtest 'Digit Contract' => sub {
    for my $shortcode (keys %$tests) {
        my $response = BOM::Pricing::v4::PricingEndpoint->new({
                shortcode => $shortcode,
                currency  => 'USD'
            })->get();

        my $expected = $tests->{$shortcode};
        cmp_deeply($response, $expected, "Correct response for $shortcode");
    }
};

done_testing();


use Test::Most;
use BOM::Pricing::v4::PricingEndpoint;

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

my $engine = BOM::Pricing::v4::PricingEndpoint->new({
    shortcode => "DIGITMATCH_R_10_18.18_0_5T_7_0",
    currency  => 'USD'
});
$engine->parameters->{bet_type} = 'testError';
dies_ok { $engine->pricing_engine_name } 'die for wrong bet_type';

done_testing();


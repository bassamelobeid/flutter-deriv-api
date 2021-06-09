use strict;
use warnings;
use Test::MockModule;
use Plack::Test;
use Test::More;
use Plack::Util;
use HTTP::Request::Common;
use JSON::MaybeXS;

my $mock_lc = Test::MockModule->new('BOM::Pricing::v4::PricingEndpoint');
$mock_lc->mock(
    get => sub {
        my $self = shift;
        return {
            theo_probability => 0.1,
            currency         => $self->currency,
            shortcode        => $self->shortcode,
        };
    });

my $app = Plack::Util::load_psgi("bin/pricer_http.psgi");

test_psgi $app, sub {
    my $cb = shift;

    my $res = $cb->(GET "/unsupported_version/a/b");
    is $res->code, 404;

    $res = $cb->(GET "/v1/USD/");
    is $res->code, 400;
    $res = $cb->(GET "/v1//DIGITMATCH_R_10_18.18_0_5T_7_0");
    is $res->code, 400;

    $res = $cb->(GET "/v1/USD/DIGITMATCH_R_10_18.18_0_5T_7_0");
    is $res->code, 200;
    is_deeply(
        JSON::MaybeXS->new()->decode($res->content),
        {
            theo_probability => 0.1,
            currency         => "USD",
            shortcode        => "DIGITMATCH_R_10_18.18_0_5T_7_0",
        });

    $res = $cb->(POST "/v1/EUR/DIGITMATCH_R_50_18.18_0_5T_7_0");
    is $res->code, 200;
    is_deeply(
        JSON::MaybeXS->new()->decode($res->content),
        {
            theo_probability => 0.1,
            currency         => "EUR",
            shortcode        => "DIGITMATCH_R_50_18.18_0_5T_7_0",
        });
};

done_testing;

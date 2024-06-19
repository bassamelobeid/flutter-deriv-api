use strict;
use warnings;
use Plack::Test;
use Test::More;
use Plack::Util;
use HTTP::Request::Common;
use JSON::MaybeXS;

my $app = Plack::Util::load_psgi("bin/pricer_http.psgi");

test_psgi $app, sub {
    my $cb = shift;
    my $res;
    my $jsn;

    # unsupported pricing engine
    $res = $cb->(GET "/v1/ASIANU_R_10_0_9T_S0P_0/USD");
    $jsn = JSON::MaybeXS->new()->decode($res->content);
    is $jsn->{error}, 'Unknown';

    # Invalid shortcode
    $res = $cb->(GET "/v1/invalid_short_is_here/USD");
    $jsn = JSON::MaybeXS->new()->decode($res->content);
    is $jsn->{error}, 'Unknown';

};

done_testing;

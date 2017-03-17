package BOM::Pricing::v3::Utility;

use strict;
use warnings;

use DataDog::DogStatsd::Helper qw(stats_inc);

sub create_error {
    my $args = shift;
    stats_inc("bom_pricing_rpc.v_3.error", {tags => ['code:' . $args->{code},]});
    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{continue_price_stream} ? (continue_price_stream => $args->{continue_price_stream}) : (),
            $args->{message}               ? (message               => $args->{message})               : (),
            $args->{details}               ? (details               => $args->{details})               : ()}};
}

1;

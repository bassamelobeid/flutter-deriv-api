package BOM::OAuth::Helper;

use strict;
use warnings;

sub extract_brand_from_params {
    my ($self, $params) = @_;
    # extract encoded brand name from parameters curried from oneall

    my $brand = (grep { /(?:amp;)brand/ } keys $params)[0];
    # if brand contains empty string return undef
    return undef unless $brand;
    return $params->{$brand};
}

1;

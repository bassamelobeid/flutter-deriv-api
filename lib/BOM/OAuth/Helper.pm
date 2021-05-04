package BOM::OAuth::Helper;

use strict;
use warnings;

=head2 extract_brand_from_params

Return undef or brand name if exists.

=cut

sub extract_brand_from_params {
    my ($self, $params) = @_;

    # extract encoded brand name from parameters curried from oneall
    my $brand_key = (grep { /(?:amp;){0,1}brand/ } keys %$params)[0];

    return undef unless $brand_key;    ## no critic (ProhibitExplicitReturnUndef)

    my $brand = $params->{$brand_key};

    return undef unless $brand;        ## no critic (ProhibitExplicitReturnUndef)

    if (ref($brand) eq 'ARRAY') {
        return undef unless $brand->[0] =~ /\w+/;    ## no critic (ProhibitExplicitReturnUndef)

        return $brand->[0];
    }

    return $brand;
}

1;

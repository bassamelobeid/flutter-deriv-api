package BOM::MarketData::Rates;

use Moose;
extends 'BOM::MarketData';

use Date::Utility;

has rates => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_rates {
    return shift->document->{rates};
}

=head1 rate_for

Returns the rate for a particular timeinyears for symbol.
->rate_for(7/365)

=cut

sub rate_for {
    my ($self, $tiy) = @_;

    my $interp = Math::Function::Interpolator->new(points => $self->rates);
    return $interp->linear($tiy * 365) / 100;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package BOM::MarketData::Fetcher::VolSurface;

use Moose;

use Module::Load::Conditional qw( can_load );
use Carp qw(croak);

=head1 fetch_surface

Like a factory for BOM::MarketData::VolSurface, will give you an instance of
the relevant sub-class for the underlying you give. The instances themselves
are automatically associated with a corresponding document in the DB, so
asking the instance for data has the effect of loading from DB.

=cut

sub fetch_surface {
    my ($self, $args) = @_;

    my $underlying   = $args->{underlying};
    my $class        = 'BOM::MarketData::VolSurface::' . ucfirst lc $underlying->volatility_surface_type;

    if (not can_load(modules => {$class => undef})) {
        croak "Could not load volsurface for " . $underlying->symbol;
    }
    my $surface_args = {
        underlying => $args->{underlying},
        $args->{for_date} ? (for_date => $args->{for_date}) : ($underlying->for_date) ? (for_date => $underlying->for_date) : (),
        $args->{cutoff} ? (cutoff => $args->{cutoff}) : (),
    };
    return $class->new($surface_args);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

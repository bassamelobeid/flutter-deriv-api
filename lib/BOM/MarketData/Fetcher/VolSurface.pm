package BOM::MarketData::Fetcher::VolSurface;

use Moose;

use Quant::Framework::VolSurface::Delta;
use Quant::Framework::VolSurface::Moneyness;

use BOM::MarketData::VolSurface::Flat;

=head1 fetch_surface

Like a factory for Quant::Framework::VolSurface, will give you an instance of
the relevant sub-class for the underlying you give. The instances themselves
are automatically associated with a corresponding document in the DB, so
asking the instance for data has the effect of loading from DB.

=cut

sub fetch_surface {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $class      = 'Quant::Framework::VolSurface::' . ucfirst lc $underlying->volatility_surface_type;
    $class = 'BOM::MarketData::VolSurface::Flat' if lc($underlying->volatility_surface_type) eq 'flat';

    my $module = $class;
    if (not $INC{($module =~ s!::!/!gr) . '.pm'}) {
        die "Could not load volsurface for " . $underlying->symbol;
    }
    my $surface_args = {
        underlying       => $args->{underlying},
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($args->{for_date} // $underlying->for_date),
        $args->{for_date} ? (for_date => $args->{for_date}) : ($underlying->for_date) ? (for_date => $underlying->for_date) : (),
    };

    $surface_args->{underlying} = $args->{underlying} if lc($underlying->volatility_surface_type) eq 'flat';

    return $class->new($surface_args);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

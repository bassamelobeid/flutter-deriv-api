package BOM::Product::Role::NonBinary;

use Moose::Role;
use Time::Duration::Concise;

has ticks_for_lookbacks => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_ticks_for_lookbacks {

    my $self      = shift;
    my $now       = $self->date_pricing->epoch;
    my $end_epoch = $now > $self->date_expiry->epoch ? $self->date_expiry->epoch : $now;

    my @ticks_since_start = @{
        $self->underlying->ticks_in_between_start_end({
                start_time => $self->date_start->epoch,
                end_time   => $end_epoch,
            })};

    return \@ticks_since_start;

}

1;

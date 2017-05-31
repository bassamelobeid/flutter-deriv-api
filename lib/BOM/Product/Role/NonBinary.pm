package BOM::Product::Role::NonBinary;

use Moose::Role;
use Time::Duration::Concise;
use List::Util qw(min max first);

has [qw(ticks_for_lookbacks spot_min spot_max)] => (
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

sub _build_spot_min {
    my $self = shift;

    my @ticks_since_start = @{$self->ticks_for_lookbacks};

    my @quote = map { $_->{quote} } @ticks_since_start;
    my $min = min(@quote);

    return $min;
}

sub _build_spot_max {
    my $self = shift;

    my @ticks_since_start = @{$self->ticks_for_lookbacks};

    my @quote = map { $_->{quote} } @ticks_since_start;
    my $max = max(@quote);

    return $max;
}

sub _build_priced_with_intraday_model {
    return 0;
}

override _build_theo_price => sub {
    my $self = shift;

    return $self->pricing_engine->theo_probability;
};

1;

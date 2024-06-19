package BOM::Product::Contract::Strike::Turbos;

use strict;
use warnings;

use List::Util          qw(max);
use BOM::Product::Utils qw(roundup);

=head2 SECONDS_IN_A_YEAR

How long is a 365 day year in seconds

=cut

use constant {SECONDS_IN_A_YEAR => 31536000};

=head2 strike_price_choices

Returns a range of strike price that is calculated

=cut

sub strike_price_choices {
    my $args = shift;

    my $ul           = $args->{underlying};
    my $current_spot = $args->{current_spot};
    my $n_max        = $args->{n_max};
    my $t            = $args->{min_distance_from_spot};
    my $n            = $args->{num_of_barriers} - 1;
    my $sigma        = $args->{sigma};

    my $beta  = max(($sigma * sqrt($t / SECONDS_IN_A_YEAR)), (1 / ($n_max * $current_spot)));
    my $alpha = ((0.5 / $beta)**(1 / $n)) - 1;

    my @strike_price_choices;
    for (my $i = 0; $i <= $n; $i++) {
        my $distance_factor   = $beta * ((1 + $alpha)**$i);
        my $distance_relative = $current_spot * $distance_factor;
        my $barrier_offset    = roundup($distance_relative, $ul->pip_size);
        $barrier_offset = $ul->pipsized_value($barrier_offset);
        push @strike_price_choices, $barrier_offset;
    }

    return \@strike_price_choices;
}

=head2 prepend_barrier_offsets

Prepend the barrier offsets with '-' for TURBOSLONG or '+' for TURBOSSHORT

=cut

sub prepend_barrier_offsets {
    my ($code, $barrier_choices) = @_;

    return $code eq 'TURBOSLONG'
        ? [map { '-' . $_ } @{$barrier_choices}]
        : [map { '+' . $_ } @{$barrier_choices}];
}

1;

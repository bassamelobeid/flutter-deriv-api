package BOM::Product::Contract::Strike::Turbos;

use strict;
use warnings;

use POSIX     qw(ceil floor);
use Math::CDF qw( qnorm );

use List::Util            qw(max min);
use POSIX                 qw(ceil floor);
use Format::Util::Numbers qw/roundnear roundcommon/;
use Math::Round           qw(round);
use BOM::Config::Runtime;

=head2 SECONDS_IN_A_YEAR

How long is a 365 day year in seconds

=cut

use constant {SECONDS_IN_A_YEAR => 31536000};

=head2 roundup

round up a value
roundup(63800, 1000) = 64000

=cut

sub roundup {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    return ceil($value_to_round / $precision) * $precision;
}

=head2 rounddown

round down a value
roundown(63800, 1000) = 63000

=cut

sub rounddown {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    return floor($value_to_round / $precision) * $precision;
}

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
    my $sentiment    = $args->{sentiment};

    my $alpha = ((0.5 / max(($sigma * sqrt($t / SECONDS_IN_A_YEAR)), (1 / ($n_max * $current_spot))))**(1 / $n)) - 1;
    my $beta  = max(($sigma * sqrt($t / SECONDS_IN_A_YEAR)), (1 / ($n_max * $current_spot)));

    my @strike_price_choices;
    for (my $i = 0; $i <= $n; $i++) {
        my $distance_factor   = $beta * ((1 + $alpha)**$i);
        my $distance_relative = $current_spot * $distance_factor;
        $distance_factor = roundup($distance_relative, $ul->pip_size);
        $distance_factor = $sentiment eq 'up' ? "-$distance_factor" : "+$distance_factor";
        push @strike_price_choices, $distance_factor;
    }

    return \@strike_price_choices;
}

1;

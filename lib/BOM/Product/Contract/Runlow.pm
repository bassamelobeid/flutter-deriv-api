package BOM::Product::Contract::Runlow;

use Moose;

extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier',
    'BOM::Product::Role::AmericanExpiry' => {-excludes => ['_build_hit_tick']},
    'BOM::Product::Role::HighLowRuns';

sub check_expiry_conditions {
    my $self = shift;

    my @ticks = @{$self->_get_ticks_since_start() // []};

    # ticks will be undefined if there's no tick(s) after entry spot
    return 0 unless @ticks;

    for (my $i = 0; $i < $#ticks; $i++) {
        my $prev = $ticks[$i];
        my $next = $ticks[$i + 1];
        if (defined $prev and defined $next and $prev->{quote} - $next->{quote} <= 0) {
            $self->_hit_tick($next);
            $self->value(0);
            return 1;
        }

    }

    # + 1 because including entry tick
    if (@ticks == $self->ticks_to_expiry) {
        $self->value($self->payout);
        return 1;
    } else {
        return 0;
    }
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

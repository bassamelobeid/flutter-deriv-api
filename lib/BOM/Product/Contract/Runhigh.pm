package BOM::Product::Contract::Runhigh;

use Moose;

extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier',
    'BOM::Product::Role::AmericanExpiry' => {-excludes => ['_build_hit_tick']},
    'BOM::Product::Role::HighLowRuns';

sub check_expiry_conditions {
    my $self = shift;

    my $value = $self->hit_tick ? 0 : $self->payout;
    $self->value($value);

    return;
}

sub _build_hit_tick {
    my $self = shift;

    my @ticks = @{$self->_all_ticks() // []};

    # ticks will be undefined if there's no tick(s) after entry spot
    return unless @ticks;

    for (my $i = 0; $i < $#ticks; $i++) {
        my $prev = $ticks[$i];
        my $next = $ticks[$i + 1];
        if (defined $prev and defined $next and $prev->{quote} - $next->{quote} >= 0) {
            return $next;
        }
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

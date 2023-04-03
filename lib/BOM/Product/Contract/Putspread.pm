package BOM::Product::Contract::Putspread;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Callputspread';

use List::Util qw(min max);
use BOM::Product::Pricing::Greeks::ZeroGreek;

=head2 _build_greek_engine
We don't have greeks for callspread defined. Overriding this
=cut

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::ZeroGreek->new({bet => shift});
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->high_barrier->as_absolute - $self->exit_tick->quote) * $self->multiplier;
        $self->value(min($self->payout, max(0, $value)));
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

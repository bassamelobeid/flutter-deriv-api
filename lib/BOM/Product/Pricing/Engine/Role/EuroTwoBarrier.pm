package BOM::Product::Pricing::Engine::Role::EuroTwoBarrier;

=head1 NAME

BOM::Product::Pricing::Engine::Role::EuroTwoBarrier


=head1 DESCRIPTION

A Moose role which provides a standard way to price Euro two barrier options by combining CALLs and PUTs.

=cut

use Moose::Role;

use BOM::Product::ContractFactory qw( make_similar_contract );
use Math::Util::CalculatedValue::Validatable;

requires 'bet';

=head1 ATTRIBUTES

=cut

has euro_two_barrier_probability => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
);

sub _build_euro_two_barrier_probability {

    my $self = shift;
    my $bet  = $self->bet;

    my $prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'euro_two_barrier_probability',
        description => 'Priced as a combination of CALL/PUT.',
        set_by      => __PACKAGE__,
        minimum     => 0,
        maximum     => 1,
    });

    if ($bet->sentiment eq 'high_vol') {
        $prob->include_adjustment('add', $self->two_barrier_miss_prob);
    } else {
        $prob->include_adjustment('reset',    $bet->discounted_probability);
        $prob->include_adjustment('subtract', $self->two_barrier_miss_prob);
    }

    return $prob;
}

sub two_barrier_miss_prob {
    my $self = shift;
    my $bet  = $self->bet;

    # Call on the high barrier.
    my $call_prob = BOM::Product::ContractFactory::make_similar_contract(
        $bet,
        {
            bet_type => 'CALL',
            barrier  => $bet->high_barrier->supplied_barrier,
        })->theo_probability;
    # Put on the low_barrier.
    my $put_prob = BOM::Product::ContractFactory::make_similar_contract(
        $bet,
        {
            bet_type => 'PUT',
            barrier  => $bet->low_barrier->supplied_barrier,
        })->theo_probability;

    my $miss_prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'two_barrier_miss',
        description => 'Probability of ending outside both barriers',
        set_by      => __PACKAGE__,
    });
    $miss_prob->include_adjustment('reset', $call_prob);
    $miss_prob->include_adjustment('add',   $put_prob);

    return $miss_prob;
}

1;

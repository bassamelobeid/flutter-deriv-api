package BOM::Product::Pricing::Engine::Digits;

use Moose;
extends 'BOM::Product::Pricing::Engine';

use BOM::Platform::Context qw(localize);

use List::Util qw(first min max);
use Math::Util::CalculatedValue::Validatable;

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            DIGITMATCH => 1,
            DIGITDIFF  => 1,
            DIGITOVER  => 1,
            DIGITUNDER => 1,
            DIGITODD   => 1,
            DIGITEVEN  => 1,
        };
    },
);

has probability => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_probability {
    my $self = shift;

    my $winning_digits = $self->winning_digits;

    my $prob_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theoretical_probability',
        description => 'digit win estimate',
        set_by      => __PACKAGE__,
        minimum     => 0.10,
        maximum     => 0.90,
        base_amount => $winning_digits / 10,
    });

    return $prob_cv;
}

has winning_digits => (
    is         => 'ro',
    isa        => 'Int',
    lazy_build => 1,
);

sub _build_winning_digits {
    my $self = shift;

    my $contract  = $self->bet;
    my $sentiment = $contract->sentiment;
    my $digit     = $contract->barrier->as_absolute;

    return
          ($sentiment eq 'match')  ? 1
        : ($sentiment eq 'differ') ? 9
        : ($sentiment eq 'over')   ? (9 - $digit)
        : ($sentiment eq 'under')  ? $digit
        : ($sentiment eq 'odd' or $sentiment eq 'even') ? 5
        :                                                 0;
}

override bs_probability => sub {
    my $self = shift;

    # Not really a financial instrument, so we'll say 'BS' is theo.
    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'bs_probability',
        description => 'Theoretical value',
        set_by      => __PACKAGE__,
        base_amount => $self->probability->amount,
    });
};

has [qw(commission_markup)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_commission_markup {
    my $self = shift;

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_markup',
        description => 'equivalent to tick trades',
        set_by      => __PACKAGE__,
        base_amount => 0.01,
    });
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

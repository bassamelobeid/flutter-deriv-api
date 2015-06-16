package BOM::Product::Pricing::Engine::Digits;

use Moose;
extends 'BOM::Product::Pricing::Engine';

use BOM::Platform::Context qw(localize);

use List::Util qw(first min max);
use Math::Util::CalculatedValue::Validatable;
use Math::Function::Interpolator;

my %prob_commission;

BEGIN {

    my $interp = Math::Function::Interpolator->new(
        points => {
            0.10 => 0.0015228426395939,    # 10-for-1, with 1.5% commission on stake
            0.50 => 0.005,                 # 50.50 for 50/50
            0.90 => 1 / 110,               # 10% return
        });

    %prob_commission = map { $_ => $interp->quadratic($_) } map { $_ / 100 } (10 .. 90);    # We only need 5% steps, but do 1% steps.
}

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

    my $contract  = $self->bet;
    my $sentiment = $contract->sentiment;
    my $digit     = $contract->barrier->as_absolute;

    my $prob_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theoretical_probability',
        description => 'digit win estimate',
        set_by      => __PACKAGE__,
        minimum     => 0.10,
        maximum     => 0.90,
        base_amount => ($sentiment eq 'match') ? 0.10
        : ($sentiment eq 'differ') ? 0.90
        : ($sentiment eq 'over')   ? (9 - $digit) / 10
        : ($sentiment eq 'under')  ? $digit / 10
        : ($sentiment eq 'odd' or $sentiment eq 'even') ? 0.50
        : 0
    });

    if (($sentiment eq 'under' and $digit == 0) or ($sentiment eq 'over' and $digit == 9)) {
        my @range = ($sentiment eq 'under') ? (1, 9) : (0, 8);
        $prob_cv->add_errors({
                severity          => 100,
                message           => $digit . ' digit [' . $contract->bet_type->code . ']',
                message_to_client => localize('Digit must be in the range of [_1] to [_2].', @range)});
    }

    return $prob_cv;
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

has model_markup => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_model_markup {
    my $self = shift;

    my $sentiment = $self->bet->sentiment;
    my $markup_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'model_markup',
        description => 'equivalent to tick trades',
        set_by      => __PACKAGE__,
        minimum     => 0,
        maximum     => 1,
        base_amount => 0,
    });
    my $commission_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_markup',
        description => 'equivalent to tick trades',
        set_by      => __PACKAGE__,
        base_amount => $prob_commission{$self->probability->amount},
    });

    my $risk_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'A set of markups added to accommodate for pricing risk',
        set_by      => __PACKAGE__,
        base_amount => 0,
    });

    $markup_cv->include_adjustment('add', $commission_markup);
    $markup_cv->include_adjustment('add', $risk_markup);

    return $markup_cv;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

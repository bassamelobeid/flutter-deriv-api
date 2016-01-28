package BOM::Product::Pricing::Engine::Digits;

use Moose;
extends 'BOM::Product::Pricing::Engine';

use BOM::Platform::Context qw(localize);
use BOM::Utility::ErrorStrings qw( format_error_string );

use List::Util qw(first min max);
use Math::Util::CalculatedValue::Validatable;

# Commissions for number of single-digit (base 10) wins
# Quadratically interpolated to match the former tick trades and give nice "even-money" numbers.
my @winning_digits_commission = (
    0.000749452007383467,    # 0: invalid, but present to allow pricing
    0.0015228426395939,      # 1: 10-for-1, with 1.5% commission on stake
    0.00233459275496077,     # 2: interpolated
    0.00318470235348408,     # 3: interpolated
    0.00407317143516382,     # 4: interpolated
    0.005,                   # 5: 50.50 for 50/50
    0.00596518804799262,     # 6: interpolated
    0.00696873557914168,     # 7: interpolated
    0.00801064259344717,     # 8: interpolated
    0.00909090909090909,     # 9: 10% return
);

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

    if ($winning_digits == 0) {
        my $contract  = $self->bet;
        my $sentiment = $contract->sentiment;
        my @range     = ($sentiment eq 'under') ? (1, 9) : (0, 8);    # Can only happen for over/under
        $prob_cv->add_errors({
                severity => 100,
                message  => format_error_string(
                    'No winning digits',
                    code      => $contract->code,
                    selection => $contract->barrier->as_absolute,
                ),
                message_to_client => localize('Digit must be in the range of [_1] to [_2].', @range)});
    }

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

has model_markup => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_model_markup {
    my $self = shift;

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
        minimum     => 0.005,
        base_amount => $winning_digits_commission[$self->winning_digits],
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

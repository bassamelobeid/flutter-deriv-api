package BOM::Product::Pricing::Engine::Digits;

use Moose;
extends 'BOM::Product::Pricing::Engine';

use Math::Util::CalculatedValue::Validatable;

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            DIGITMATCH => 1,
            DIGITDIFF  => 1,
        };
    },
);

has probability => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_probability {
    my $self = shift;

    my $sentiment = $self->bet->sentiment;
    my $prob_cv;
    # Literally nothing about time or predicition matters here.
    if ($sentiment eq 'match') {
        $prob_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'theoretical_probability',
            description => 'will win one time in ten',
            set_by      => __PACKAGE__,
            minimum     => 0,
            maximum     => 1,
            base_amount => 0.10,
        });
    } elsif ($sentiment eq 'differ') {
        $prob_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'theoretical_probability',
            description => 'will win nine times out of ten',
            set_by      => __PACKAGE__,
            minimum     => 0,
            maximum     => 1,
            base_amount => 0.90,
        });

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
    my $commission_markup;
    # Literally nothing about time or predicition matters here.
    if ($sentiment eq 'match') {
        $commission_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'commission_markup',
            description => 'equivalent to tick trades',
            set_by      => __PACKAGE__,
            minimum     => 0,
            maximum     => 1,
            base_amount => 0.0015228426395939,            # 10:1 - 1.5%
        });
    } elsif ($sentiment eq 'differ') {
        $commission_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'commission_markup',
            description => 'equivalent to tick trades',
            set_by      => __PACKAGE__,
            minimum     => 0,
            maximum     => 1,
            base_amount => 1 / 110,                       # 10% return.
        });
    }

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

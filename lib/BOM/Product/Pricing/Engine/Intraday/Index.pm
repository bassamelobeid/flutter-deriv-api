package BOM::Product::Pricing::Engine::Intraday::Index;

use Moose;
extends 'BOM::Product::Pricing::Engine::Intraday';

use Time::Duration::Concise;
use BOM::Platform::Context qw(localize);

=head2 probability

probability for Intraday Index is hard-coded to 55%.
There's no model in this price calculation yet.

=cut

has [qw(pricing_vol probability risk_markup)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_pricing_vol {
    return shift->bet->_pricing_args->{iv};
}

sub _build_risk_markup {
    my $self = shift;

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'additional 2.5% markup for intraday indices',
        set_by      => __PACKAGE__,
        base_amount => 0.025,
    });
}

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            CALL => 1,
            PUT  => 1,
        };
    },
);

sub _build_probability {
    my $self = shift;

    my $prob_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theoretical_probability',
        description => 'theoretical probability for intraday index',
        set_by      => __PACKAGE__,
        minimum     => 0.5,                                            # we don't go lower than 0.5
        maximum     => 1,
        base_amount => $self->formula->($self->_formula_args),
    });

    $prob_cv->include_adjustment('add', $self->risk_markup);

    return $prob_cv;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

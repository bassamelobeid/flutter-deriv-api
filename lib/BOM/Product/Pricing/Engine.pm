package BOM::Product::Pricing::Engine;

=head1 NAME

BOM::Product::Pricing::Engine

=head1 DESCRIPTION

Base class for all pricing engines

=head1 USAGE

Extend this class by:

extends 'BOM::Product::Pricing::Engine';

=cut

use Moose;
use Math::Business::BlackScholesMerton::Binaries;
use Math::Business::BlackScholesMerton::NonBinaries;
use Math::Util::CalculatedValue::Validatable;
use YAML::XS qw(LoadFile);

my %engine_compatibility = (
    basic => LoadFile('/home/git/regentmarkets/bom/config/intraday_engine_compatibility/basic.yml'),
);

=head1 ATTRIBUTES

=head2 bet

A required parameter to this engine to price.

=cut

has bet => (
    is       => 'ro',
    isa      => 'BOM::Product::Contract',
    weak_ref => 1,
    required => 1,
);

has formula => (
    is         => 'ro',
    isa        => 'CodeRef',
    lazy_build => 1,
);

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {};
    },
);

has [qw(bs_probability probability d2)] => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
);

sub BUILD {
    my $self = shift;

    my $claimtype = $self->bet->pricing_code;
    die 'Invalid claimtype[' . $claimtype . '] for engine.' unless $self->_supported_types->{$claimtype};

    return;
}

# For now this is easy, but just in case things get complicated later
sub _build_formula {
    my $self = shift;

    my $module =
          $self->bet->payout_type eq 'binary'     ? 'Math::Business::BlackScholesMerton::Binaries'
        : $self->bet->payout_type eq 'non-binary' ? 'Math::Business::BlackScholesMerton::NonBinaries'
        :                                           undef;

    die 'could not find formula to price ' . $self->bet->pricing_code unless $module;

    my $formula = $module->can(lc $self->bet->pricing_code) or die 'could not price ' . $self->bet->pricing_code . ' with ' . $module;

    return $formula;
}

=head2 bs_probability

The unadjusted Black-Scholes probability

=cut

sub _build_bs_probability {
    my $self = shift;

    my $bet  = $self->bet;
    my $args = $bet->_pricing_args;

    my @barrier_args = ($bet->two_barriers) ? ($args->{barrier1}, $args->{barrier2}) : ($args->{barrier1});
    my $tv = $self->formula->($args->{spot}, @barrier_args, $args->{t}, $bet->discount_rate, $bet->mu, $args->{iv}, $args->{payouttime_code});

    my @max     = ($bet->payout_type eq 'binary') ? (maximum => 1) : ();
    my $bs_prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bs_probability',
        description => 'The Black-Scholes theoretical value',
        set_by      => 'BOM::Product::Pricing::Engine',
        minimum     => 0,
        @max,
        base_amount => $tv,
    });

    # If BS is very high, we don't want that business, even if it makes sense.
    if ($tv > 0.999) {
        $bs_prob->include_adjustment('add', $self->no_business_probability);
    }

    return $bs_prob;
}

has no_business_probability => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_no_business_probability',
);

sub _build_no_business_probability {
    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'no_business',
        description => 'setting probability to 1',
        set_by      => 'BOM::Product::Pricing::Engine::VannaVolga',
        base_amount => 1,
    });

}

sub _build_d2 {
    my $self = shift;

    my $bet  = $self->bet;
    my $args = $bet->_pricing_args;

    my $d2 =
        Math::Business::BlackScholesMerton::Binaries::d2($args->{spot}, $args->{barrier1}, $args->{t}, $bet->discount_rate, $bet->mu, $args->{iv});

    my $d2_ret = Math::Util::CalculatedValue::Validatable->new({
        name        => 'd2',
        description => 'The D2 parameter',
        set_by      => 'BOM::Product::Pricing::Engine',
        base_amount => $d2
    });

    return $d2_ret;
}

=head2 probability

The probability asccording to this engine for the given bet by default the BS probability;

=cut

sub _build_probability {
    my $self = shift;

    return $self->bs_probability;
}

sub is_compatible {
    my (undef, $to_load, $metadata) = @_;

    my $permitted = $engine_compatibility{$to_load} // die 'Unknown compatibility file[' . $to_load . ']';

    for my $key (qw(underlying_symbol contract_category expiry_type start_type barrier_category)) {
        if (exists $permitted->{$metadata->{$key}}) {
            $permitted = $permitted->{$metadata->{$key}};
            next;
        }
        # return is no match
        return;
    }

    my ($min, $max) = map { Time::Duration::Concise->new(interval => $permitted->{$_}) } qw(min max);

    return if ($metadata->{contract_duration} < $min->seconds || $metadata->{contract_duration} > $max->seconds);

    # if everything is good, then can price.
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

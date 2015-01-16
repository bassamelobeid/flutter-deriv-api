package BOM::Greeks::FiniteDifference;

use Moose;

use List::Util qw(reduce);

extends 'BOM::Product::Pricing::Greeks';
use BOM::Product::ContractFactory qw( produce_contract );

has bet => (
    is       => 'ro',
    isa      => 'BOM::Product::Contract',
    required => 1,
);

has [qw(spot_epsilon sigma_epsilon time_epsilon)] => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

has [qw(model_greeks)] => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

has _method => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has [qw(original_params epsigma_prices epspot_prices eptime_prices dualep_prices)] => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build__method {
    my $self = shift;

    return ($self->model_greeks) ? 'theo_probability' : 'bs_probability';
}

sub _build_spot_epsilon {
    my $self = shift;

    return $self->bet->underlying->pip_size;
}

sub _build_sigma_epsilon {
    my $self = shift;

    # Default to 0.003 per some fitting.
    return 0.003;
}

sub _build_time_epsilon {
    my $self = shift;

    # Default to 0.3% difference in time
    return $self->bet->timeinyears->amount * 0.003;
}

# This needs to be implemented after we get the individual ones.
sub get_greeks {

    my $self = shift;

    return {
        delta => $self->delta,
        theta => $self->theta,
        gamma => $self->gamma,
        vega  => $self->vega,
        vanna => $self->vanna,
        volga => $self->volga,
    };
}

# This just wraps the inividual attributes so that it works like our
# old non-moose version.
sub get_greek {
    my ($self, $greek) = @_;

    die 'Unknown greek[' . $greek . ']' if not $self->_available_greeks->{$greek};

    return $self->$greek;
}

sub _build_delta {
    my $self = shift;

    my $ep = $self->epspot_prices;

    my $delta = ($ep->{2} - $ep->{-2}) / (4 * $self->spot_epsilon);

    return $delta;    # * $self->bet->current_spot;
}

sub _build_gamma {
    my $self = shift;

    my $ep = $self->epspot_prices;

    my $gamma = ($ep->{-1} - 2 * $ep->{0} + $ep->{1}) / ($self->spot_epsilon**2);

#    my $gamma = (-1 * $ep->{-2} + 16 * $ep->{-1} - 30 * $ep->{0} + 16 * $ep->{1} - $ep->{2}) / (12 * ($self->spot_epsilon**2));

#    my $gamma = (2 * $ep->{-2} - $ep->{-1} - 2 * $ep->{0} - $ep->{1} + 2 * $ep->{2}) / (14 * ($self->spot_epsilon**2));

    return $gamma;    # * $self->bet->current_spot**2;
}

sub _build_theta {
    my $self = shift;

    my $ep = $self->eptime_prices;

    my $theta = ($ep->{-2} - $ep->{2}) / (4 * $self->time_epsilon);

    return $theta;
}

sub _build_vega {

    my $self = shift;

    my $ep = $self->epsigma_prices;

    my $vega = ($ep->{2} - $ep->{-2}) / (4 * $self->sigma_epsilon);
    #my $vega = ($ep->{1} - $ep->{0}) / $self->sigma_epsilon;
    #my $vega = ($ep->{0} - $ep->{-1}) / $self->sigma_epsilon;

    return $vega;
}

sub _build_vanna {
    my $self = shift;

    my $ep = $self->dualep_prices;

    my $vanna = ($ep->{1}->{1} - $ep->{-1}->{1} - $ep->{1}->{-1} + $ep->{-1}->{-1}) / (4 * $self->sigma_epsilon * $self->spot_epsilon);

    return $vanna;    # * $self->bet->current_spot;
}

sub _build_volga {
    my $self = shift;

    my $ep = $self->epsigma_prices;

    # Wystup 2nd Order Approx
    #my $volga = ($ep->{-1} - 2 * $ep->{0} + $ep->{1}) / ($self->sigma_psilons**2);
    #my $volga = (2 * $ep->{-2} - $ep->{-1} - 2 * $ep->{0} - $ep->{1} + 2 * $ep->{2}) / (14 * ($self->sigma_epsilon**2));

    my $volga = (-1 * $ep->{-2} + 16 * $ep->{-1} - 30 * $ep->{0} + 16 * $ep->{1} - $ep->{2}) / (12 * ($self->sigma_epsilon**2));

    return $volga;
}

sub _build_epsigma_prices {
    my $self = shift;

    return $self->_single_pricing_arg_adjust('iv', $self->sigma_epsilon);
}

sub _build_epspot_prices {
    my $self = shift;

    return $self->_single_pricing_arg_adjust('spot', $self->spot_epsilon);
}

sub _build_eptime_prices {
    my $self = shift;

    return $self->_single_pricing_arg_adjust('t', $self->time_epsilon);
}

sub _single_pricing_arg_adjust {
    my ($self, $which, $eps) = @_;

    my $bet             = $self->bet;
    my $prob_method     = $self->_method;
    my %original_params = %{$self->original_params};
    my %prices          = (0 => $bet->$prob_method->amount);

    foreach my $level (-2 .. 2) {
        if (not exists $prices{$level}) {
            my %pricing_args = %{$original_params{pricing}};
            $pricing_args{$which} += $eps * $level;
            my %bet_params = %{$original_params{build}};
            $bet_params{pricing_args} = \%pricing_args;
            my $new_bet = BOM::Product::ContractFactory::produce_contract(\%bet_params);
            $prices{$level} = $new_bet->$prob_method->amount;
        }
    }

    return \%prices;
}

sub _build_dualep_prices {
    my $self            = shift;
    my $bet             = $self->bet;
    my $prob_method     = $self->_method;
    my %original_params = %{$self->original_params};
    my $epsig           = $self->sigma_epsilon;
    my $epspot          = $self->spot_epsilon;
    my %prices;

    foreach my $spotdir (-1, 1) {
        $prices{$spotdir} = {};
        foreach my $sigdir (-1, 1) {
            my %pricing_args = %{$original_params{pricing}};
            $pricing_args{iv}   += $epsig * $sigdir;
            $pricing_args{spot} += $epspot * $spotdir;
            my %bet_params = %{$original_params{build}};
            $bet_params{pricing_args} = \%pricing_args;
            my $new_bet = BOM::Product::ContractFactory::produce_contract(\%bet_params);
            $prices{$spotdir}->{$sigdir} = $new_bet->$prob_method->amount;
        }
    }

    return \%prices;
}

sub _build_original_params {
    my $self = shift;

    my $bet        = $self->bet;
    my %bet_params = %{$bet->build_parameters};
    $bet_params{volsurface} = $bet->volsurface;
    $bet_params{fordom}     = $bet->fordom;
    $bet_params{domqqq}     = $bet->domqqq;
    $bet_params{forqqq}     = $bet->forqqq;

    return {
        build   => \%bet_params,
        pricing => $bet->pricing_args,
    };
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

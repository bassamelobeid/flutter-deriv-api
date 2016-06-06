package BOM::Product::RiskProfile;

use Moose;

use BOM::Platform::Runtime;
use BOM::Platform::Static::Config;
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Market::Underlying;

use JSON qw(from_json);
use List::Util qw(first);
use List::MoreUtils qw(all);

has [qw(contract_category underlying expiry_type start_type currency)] => (
    is       => 'ro',
    required => 1,
);

has has_custom_client_limit => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

has [qw(contract_info)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_contract_info {
    my $self = shift;

    return {
        underlying_symbol => $self->underlying->symbol,
        market            => $self->underlying->market->name,
        submarket         => $self->underlying->submarket->name,
        contract_category => $self->contract_category,
        expiry_type       => $self->expiry_type,
        start_type        => $self->start_type,
    };
}

has limits => (
    is      => 'ro',
    default => sub {
        return BOM::Platform::Static::Config::quants->{risk_profile};
    },
);

has risk_profiles => (
    is      => 'ro',
    default => sub { [qw(no_business extreme_risk high_risk medium_risk low_risk)] },
);

sub get_risk_profile {
    my $self = shift;

    foreach my $p (@{$self->risk_profiles}) {
        if (first { $_->{risk_profile} eq $p } @{$self->applicable_profiles}) {
            return $p;
        }
    }

    # if it is unknown, set it to no business profile
    return $self->risk_profiles->[0];
}

sub get_turnover_limit_parameters {
    my $self = shift;

    my @turnover_params;

    foreach my $profile (@{$self->applicable_profiles}) {
        my $params = {
            name  => $profile->{name},
            limit => $self->limits->{$profile->{risk_profile}}{turnover}{$self->currency},
        };

        if (my $exp = $profile->{expiry_type}) {
            if ($exp eq 'tick') {
                $params->{tick_expiry} = 1;
            } elsif ($exp eq 'daily') {
                $params->{daily} = 1;
            } else {
                $params->{daily} = 0;
            }
        }

        if ($profile->{market}) {
            $params->{symbols} = [map { {n => $_} } get_offerings_with_filter('underlying_symbol', {market => $profile->{market}})];
        } elsif ($profile->{submarket}) {
            $params->{symbols} = [map { {n => $_} } get_offerings_with_filter('underlying_symbol', {submarket => $profile->{submarket}})];
        } elsif ($profile->{underlying_symbol}) {
            $params->{symbols} = [{n => $profile->{underlying_symbol}}];
        }

        if ($profile->{contract_category}) {
            $params->{bet_type} =
                [map { {n => $_} } get_offerings_with_filter('contract_type', {contract_category => $profile->{contract_category}})];
        }
        push @turnover_params, $params;
    }

    return \@turnover_params;
}

sub applicable_profiles {
    my $self = shift;
    return [@{$self->custom_profiles}, @{$self->custom_client_profiles}];
}

has custom_profiles => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_custom_profiles {
    my $self = shift;

    my $custom_product_profiles = from_json(BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles);

    my @profiles;
    foreach my $id (keys %$custom_product_profiles) {
        my $p = $custom_product_profiles->{$id};
        if ($self->_match_conditions($p)) {
            push @profiles, $p;
        }
    }

    my $ul           = $self->underlying;
    my $risk_profile = $ul->risk_profile;
    my $setter       = $ul->risk_profile_setter;
    # default market level profile
    push @profiles,
        +{
        risk_profile => $risk_profile,
        name         => $self->contract_info->{$setter} . '_turnover_limit',
        $setter      => $self->contract_info->{$setter},
        };

    return \@profiles;
}

has custom_client_profiles => (
    is      => 'rw',
    default => sub { [] },
);

sub include_client_profiles {
    my ($self, $client_loginid) = @_;

    if ($client_loginid) {
        my $custom_client = from_json(BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles);
        if (exists $custom_client->{$client_loginid} and my $limits = $custom_client->{$client_loginid}->{custom_limits}) {
            my @matches = map { $limits->{$_} } grep { $self->_match_conditions($limits->{$_}) } keys %$limits;
            push @{$self->custom_client_profiles}, @matches;
        }
    }

    return;
}

sub _match_conditions {
    my ($self, $custom) = @_;

    my %copy = %$custom;
    delete $copy{$_} for qw(name risk_profile);
    my %reversed = reverse %copy;
    if (all { $reversed{$self->contract_info->{$_}} } values %reversed) {
        return $custom;
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;


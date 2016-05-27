package BOM::Product::RiskProfile;

use Moose;

use BOM::Platform::Runtime;
use BOM::Platform::Static::Config;
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Market::Underlying;

use JSON qw(from_json);
use List::Util qw(first);

has contract_info => (
    is       => 'ro',
    required => 1,
);

has client_loginid => (
    is      => 'ro',
    default => undef,
);

has known_keys => (
    is      => 'ro',
    default => sub {
        {
            contract_category => 1,
            market            => 1,
            submarket         => 1,
            underlying_symbol => 1,
            expiry_type       => 1,
            start_type        => 1,
            barrier_category  => 1,
        };
    },
);

has risk_profiles => (
    is      => 'ro',
    default => sub { [qw(no_business extreme_risk high_risk medium_risk low_risk)] },
);

sub get_product_risk_profile {
    my $self = shift;

    foreach my $p (@{$self->risk_profiles}) {
        if (first { $_->{risk_profile} eq $p } @{$self->applicable_profiles}) {
            return $p;
        }
    }

    # if it is unknown, set it to no business profile
    return $self->risk_profiles->[0];
}

sub get_turnover_parameters {
    my $self = shift;

    my $limit_ref = BOM::Platform::Static::Config::quants->{risk_profile};
    my @turnover_params;
    foreach my $profile (@{$self->applicable_profiles}) {
        my $params = {
            name  => $profile->{name},
            limit => $limit_ref->{$profile->{risk_type}}->{$self->contract_info->{currency}},
        };
        $params->{tick_expiry} = 1 if $profile->{tick_expiry};
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

has applicable_profiles => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_applicable_profiles {
    my $self = shift;

    my $config                  = BOM::Platform::Runtime->instance->app_config->quants;
    my $custom_product_profiles = from_json($config->custom_product_profiles);

    my @applicable_profiles;
    foreach my $p (@$custom_product_profiles) {
        if ($self->_match_conditions($p)) {
            push @applicable_profiles, $p;
        }
    }

    if (my $id = $self->client_loginid) {
        my $custom_client_profiles = from_json($config->custom_client_profiles)->{$id};
        foreach my $p (@$custom_client_profiles) {
            if ($self->_match_conditions($p)) {
                push @applicable_profiles, $p;
            }
        }
    }

    # default market level profile
    push @applicable_profiles,
        +{
        underlying_symbol => BOM::Market::Underlying->new($self->contract_info->{underlying_symbol})->risk_profile,
        name              => 'underlying_symbol_turnover_limit',
        };

    return \@applicable_profiles;
}

sub _match_conditions {
    my ($self, $custom) = @_;

    my %reversed = reverse %$custom;
    if (all { $reversed{$self->contract_info->{$_}} } values %reversed) {
        return $custom;
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;


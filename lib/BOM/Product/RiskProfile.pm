package BOM::Product::RiskProfile;

use Moose;

use BOM::Platform::Runtime;
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Market::Underlying;

use JSON qw(from_json);
use List::Util qw(first);
use List::MoreUtils qw(all);

use constant RISK_PROFILES => [qw(no_business extreme_risk high_risk medium_risk low_risk)];

has [qw(contract_category underlying expiry_type start_type currency barrier_category)] => (
    is       => 'ro',
    required => 1,
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
        barrier_category  => $self->barrier_category,
    };
}

sub limits {
    return BOM::System::Config::quants->{risk_profile};
}

sub get_risk_profile {
    my $self = shift;

    foreach my $p (@{RISK_PROFILES()}) {
        if (first { $_->{risk_profile} eq $p } @{$self->applicable_profiles}) {
            return $p;
        }
    }

    # if it is unknown, set it to no business profile
    return RISK_PROFILES->[0];
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

        # we only need to distinguish atm and non_atm for callput.
        if (    $profile->{barrier_category}
            and $profile->{barrier_category} eq 'euro_non_atm'
            and $profile->{contract_category}
            and $profile->{contract_category} eq 'callput')
        {
            $params->{non_atm} = 1;
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

    # specific limit for spreads.
    push @profiles,
        +{
        risk_profile      => BOM::Platform::Runtime->instance->app_config->quants->spreads_daily_profit_limit,
        name              => 'spreads_daily_profit_limit',
        contract_category => 'spreads',
        }
        if $self->contract_info->{contract_category} eq 'spreads';

    return \@profiles;
}

has custom_client_profiles => (
    is      => 'rw',
    default => sub { [] },
);

my $custom_limits_txt      = '';
my $custom_limits_compiled = {};

sub get_client_profiles {
    my ($self, $loginid) = @_;

    if ($loginid) {
        my $ptr = \BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles;    # use a pointer to avoid copying
        $custom_limits_compiled = from_json($custom_limits_txt = $$ptr)                             # copy and compile
            unless $$ptr eq $custom_limits_txt;

        my $cl;
        return grep { $self->_match_conditions($_) } values %$cl
            if $cl = $custom_limits_compiled->{$loginid} and $cl = $cl->{custom_limits};
    }

    return;
}

my %_no_condition;
@_no_condition{qw(name risk_profile updated_by updated_on)} = ();

sub _match_conditions {
    my ($self, $custom) = @_;

    my $real_tests_performed;
    my $ci = $self->contract_info;
    while (my ($k, $v) = each %$custom) {
        next if exists $_no_condition{$k}; # skip test
        $real_tests_performed = 1;
        next if $v eq $ci->{$k};           # match: continue with next condition
        return;                            # no match
    }

    return $real_tests_performed;          # all conditions match

    # my %copy = %$custom;
    # delete $copy{$_} for qw(name risk_profile updated_by updated_on);

    # # if there's no condition, exit.
    # return if not keys %copy;

    # my %reversed = reverse %copy;
    # if (all { $reversed{$self->contract_info->{$_}} } values %reversed) {
    #     return $custom;
    # }

    # return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;


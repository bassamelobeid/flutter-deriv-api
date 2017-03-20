package BOM::Product::RiskProfile;

=pod

There are 5 risk profiles: no_business extreme_risk high_risk medium_risk low_risk

A risk profile defines the maximum payout per contract and/or daily turnover limit to be applied to a given client and/or landing company and/or contract type and/or underlying and/or market.

=cut

use Moose;
use JSON qw(from_json);

use LandingCompany::Offerings qw(get_offerings_with_filter);
use Finance::Asset::Market::Registry;
use Finance::Asset::SubMarket::Registry;

use BOM::Platform::Runtime;
use BOM::Platform::Config;

use constant RISK_PROFILES => [qw(no_business extreme_risk high_risk medium_risk low_risk)];

my %risk_profile_rank;
for (my $i = 0; $i < @{RISK_PROFILES()}; $i++) {
    $risk_profile_rank{RISK_PROFILES->[$i]} = $i;
}

has [
    qw(contract_category expiry_type start_type currency barrier_category symbol market_name submarket_name underlying_risk_profile underlying_risk_profile_setter)
    ] => (
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
        underlying_symbol => $self->symbol,
        market            => $self->market_name,
        submarket         => $self->submarket_name,
        contract_category => $self->contract_category,
        expiry_type       => $self->expiry_type,
        start_type        => $self->start_type,
        barrier_category  => $self->barrier_category,
    };
}

has [qw(base_profile)] => (
    is         => 'ro',
    lazy_build => 1,
);

# this is the risk profile of a contract without taking into account the client.
sub _build_base_profile {
    my $self = shift;

    my $ap = $self->custom_profiles;

    # if it is unknown, set it to no business profile
    return '' unless @$ap;

    my $min = @{RISK_PROFILES()};
    for (@$ap) {
        my $tmp = $risk_profile_rank{$_->{risk_profile}};
        $min = $tmp if $tmp < $min;
        last if $min == 0;
    }
    return RISK_PROFILES->[$min];
}

has custom_profiles => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_custom_profiles {
    my $self = shift;

    my @profiles = grep { $self->_match_conditions($_) } values %{$self->raw_custom_profiles};

    my $risk_profile = $self->underlying_risk_profile;
    my $setter       = $self->underlying_risk_profile_setter;
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

has raw_custom_profiles => (
    is         => 'ro',
    lazy_build => 1,
);

# this is a cache to avoid from_json for each contract
my $product_profiles_txt      = '';
my $product_profiles_compiled = {};

sub _build_raw_custom_profiles {
    my $self = shift;

    my $ptr = \BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles;    # use a pointer to avoid copying
    $product_profiles_compiled = from_json($product_profiles_txt = $$ptr)                        # copy and compile
        unless $$ptr eq $product_profiles_txt;

    return $product_profiles_compiled;
}

# this one is the risk profile including the client profile
sub get_risk_profile {
    my $self = shift;
    my $ap = shift || [];

    my $base = $self->base_profile;

    # if it is unknown, set it to no business profile
    return $base eq '' ? RISK_PROFILES->[0] : $base unless @$ap;

    my $min = $base eq '' ? @{RISK_PROFILES()} : $risk_profile_rank{$base};
    for (@$ap) {
        my $tmp = $risk_profile_rank{$_->{risk_profile}};
        return RISK_PROFILES->[0] if $tmp == 0;    # short cut: it cannot get less
        $min = $tmp if $tmp < $min;
    }
    return RISK_PROFILES->[$min];
}

sub get_turnover_limit_parameters {
    my $self = shift;
    my $ap = shift || [];

    return [
        map {
            my $params = {
                name  => $_->{name},
                limit => BOM::Platform::Config::quants->{risk_profile}->{$_->{risk_profile}}{turnover}{$self->currency},
            };

            if (my $exp = $_->{expiry_type}) {
                if ($exp eq 'tick') {
                    $params->{tick_expiry} = 1;
                } elsif ($exp eq 'daily') {
                    $params->{daily} = 1;
                } else {
                    $params->{daily} = 0;
                }
            }

            # we only need to distinguish atm and non_atm for callput.
            if (    $_->{barrier_category}
                and $_->{barrier_category} eq 'euro_non_atm'
                and $_->{contract_category}
                and $_->{contract_category} eq 'callput')
            {
                $params->{non_atm} = 1;
            }

            my $config = BOM::Platform::Runtime->instance->get_offerings_config;

            if ($_->{market}) {
                $params->{symbols} = [map { {n => $_} } get_offerings_with_filter($config, 'underlying_symbol', {market => $_->{market}})];
            } elsif ($_->{submarket}) {
                $params->{symbols} = [map { {n => $_} } get_offerings_with_filter($config, 'underlying_symbol', {submarket => $_->{submarket}})];
            } elsif ($_->{underlying_symbol}) {
                $params->{symbols} = [{n => $_->{underlying_symbol}}];
            }

            if ($_->{contract_category}) {
                $params->{bet_type} =
                    [map { {n => $_} } get_offerings_with_filter($config, 'contract_type', {contract_category => $_->{contract_category}})];
            }

            $params;
            } @{$self->custom_profiles},
        @$ap
    ];
}

# this is a cache to avoid from_json for each contract
my $custom_limits_txt      = '';
my $custom_limits_compiled = {};

sub get_client_profiles {
    my ($self, $loginid, $landing_company_short) = @_;

    if ($loginid && $landing_company_short) {
        my $ptr = \BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles;    # use a pointer to avoid copying
        $custom_limits_compiled = from_json($custom_limits_txt = $$ptr)                             # copy and compile
            unless $$ptr eq $custom_limits_txt;

        my @client_limits = do {
            my @limits = ();
            my $cl;
            if ($cl = $custom_limits_compiled->{$loginid} and $cl = $cl->{custom_limits}) {
                @limits = grep { $self->_match_conditions($_) } values %$cl;
            }
            @limits;
        };

        my @landing_company_limits = ();
        foreach my $custom (values %{$self->raw_custom_profiles}) {
            next unless exists $custom->{landing_company};
            next if $landing_company_short ne $custom->{landing_company};
            push @landing_company_limits, $custom if $self->_match_conditions($custom, {landing_company => $landing_company_short});
        }

        return (@client_limits, @landing_company_limits);
    }

    return;
}

my %_no_condition;
@_no_condition{qw(name risk_profile updated_by updated_on)} = ();

sub _match_conditions {
    my ($self, $custom, $additional_info) = @_;

    $additional_info = {} unless defined $additional_info;
    my $real_tests_performed;
    my $ci = {%{$self->contract_info}, %$additional_info};
    foreach my $key (keys %$custom) {
        next if exists $_no_condition{$key};    # skip test
        $real_tests_performed = 1;
        next if exists $ci->{$key} and $custom->{$key} eq $ci->{$key};    # match: continue with next condition
        return;                                                           # no match
    }

    return $real_tests_performed;                                         # all conditions match
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package BOM::Platform::RiskProfile;

=head NAME

BOM::Platform::RiskProfile - a class to get custom risk and/or commission profile.

=head DESCRIPTION

There are 5 risk profiles: no_business extreme_risk high_risk medium_risk low_risk

A risk profile defines the maximum payout per contract and/or daily turnover limit to be applied to a given client and/or landing company and/or contract type and/or underlying and/or market.

=cut

use Moose;

use List::Util qw(first max);
use JSON::MaybeXS;
use Format::Util::Numbers qw/formatnumber/;

use Finance::Asset::Market::Registry;
use Finance::Asset::SubMarket::Registry;
use LandingCompany::Registry;

use BOM::Config::Runtime;
use BOM::Config;

use constant RISK_PROFILES => [qw(no_business extreme_risk high_risk moderate_risk medium_risk low_risk)];

my $json = JSON::MaybeXS->new;
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
        next if not defined $_->{risk_profile};
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

    my @profiles = grep { $self->_match_conditions($_) } @{$self->raw_custom_risk_profiles};

    my $risk_profile = $self->underlying_risk_profile;
    my $setter       = $self->underlying_risk_profile_setter;
    # default market level profile
    push @profiles,
        +{
        risk_profile => $risk_profile,
        name         => $self->contract_info->{$setter} . '_turnover_limit',
        $setter      => $self->contract_info->{$setter},
        };

    return \@profiles;
}

has non_binary_custom_profiles => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_non_binary_custom_profiles {
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

    return \@profiles;
}

has [qw(raw_custom_risk_profiles raw_custom_commission_profiles)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_raw_custom_risk_profiles {
    my $self = shift;

    return [grep { $_->{risk_profile} } values %{$self->raw_custom_profiles}];
}

sub _build_raw_custom_commission_profiles {
    my $self = shift;

    return [grep { $_->{commission} } values %{$self->raw_custom_profiles}];
}

has raw_custom_profiles => (
    is         => 'ro',
    lazy_build => 1,
);

# this is a cache to avoid decode for each contract
my $product_profiles_txt      = '';
my $product_profiles_compiled = {};

sub _build_raw_custom_profiles {
    my $self = shift;

    my $ptr = \BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles;    # use a reference to avoid copying
    $product_profiles_compiled = $json->decode($product_profiles_txt = $$ptr)                  # copy and compile
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

sub get_non_binary_limit_parameters {
    my $self = shift;
    my $ap = shift || [];

    return [
        map {
            my $params;
            if ($_->{non_binary_contract_limit}) {
                $params = {
                    name                      => $_->{name},
                    non_binary_contract_limit => $_->{non_binary_contract_limit},
                };
            }

            $params;
            } @{$self->non_binary_custom_profiles},
        @$ap
    ];
}

sub get_turnover_limit_parameters {
    my $self = shift;
    my $ap = shift || [];

    return [
        map {
            my $params;

            $params = {
                name  => $_->{name},
                limit => BOM::Config::quants()->{risk_profile}->{$_->{risk_profile}}{turnover}{$self->currency},
            };

            if (my $exp = $_->{expiry_type}) {
                if ($exp eq 'tick') {
                    $params->{tick_expiry} = 1;
                } elsif ($exp eq 'daily') {
                    $params->{daily} = 1;
                } else {
                    $params->{daily} = 0;
                    $params->{ultra_short} = $exp eq 'ultra_short' ? 1 : 0;
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

            my $offerings_obj = _offerings_obj();

            if ($_->{underlying_symbol}) {
                $params->{symbols} = [split ',', $_->{underlying_symbol}];
            } elsif ($_->{submarket}) {
                my $submarket = $_->{submarket};
                $submarket =~ s/\s//g;
                $params->{symbols} = [$offerings_obj->query({submarket => [split ',', $submarket]}, ['underlying_symbol'])];
            } elsif ($_->{market}) {
                my $market = $_->{market};
                $market =~ s/\s//g;
                $params->{symbols} = [$offerings_obj->query({market => [split ',', $market]}, ['underlying_symbol'])];
            }

            if ($_->{contract_category}) {
                $params->{bet_type} = [$offerings_obj->query({contract_category => $_->{contract_category}}, ['contract_type'])];
            }

            $params;
            } @{$self->custom_profiles},
        @$ap
    ];
}

# this is a cache to avoid decode for each contract
my $custom_limits_txt      = '';
my $custom_limits_compiled = {};

sub get_client_profiles {
    my ($self, $loginid, $landing_company_short) = @_;

    if ($loginid && $landing_company_short) {
        my $ptr = \BOM::Config::Runtime->instance->app_config->quants->custom_client_profiles;    # use a pointer to avoid copying
        $custom_limits_compiled = $json->decode($custom_limits_txt = $$ptr)                       # copy and compile
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
        foreach my $custom (@{$self->raw_custom_risk_profiles}) {
            next unless exists $custom->{landing_company};
            next if $landing_company_short ne $custom->{landing_company};
            push @landing_company_limits, $custom if $self->_match_conditions($custom, {landing_company => $landing_company_short});
        }

        return (@client_limits, @landing_company_limits);
    }

    return;
}

sub get_current_profile_definitions {
    my $client = shift;

    my ($currency, $landing_company, $country_code);
    if ($client) {
        ($currency, $landing_company, $country_code) = ($client->currency, $client->landing_company->short, $client->residence);
    } else {
        # set some defaults here
        ($currency, $landing_company) = ('USD', 'costarica');
    }

    my $offerings_obj = _offerings_obj($landing_company, $country_code);
    my @markets =
        map { Finance::Asset::Market::Registry->get($_) } $offerings_obj->values_for_key('market');
    my $limit_ref = BOM::Config::quants()->{risk_profile};

    my %limits;
    foreach my $market (@markets) {
        my @submarket_list =
            grep { $_->risk_profile }
            map { Finance::Asset::SubMarket::Registry->get($_) } $offerings_obj->query({market => $market->name}, ['submarket']);
        if (@submarket_list) {
            my @list = map { {
                    name           => $_->display_name,
                    turnover_limit => formatnumber('amount', $currency, $limit_ref->{$_->risk_profile}{turnover}{$currency}),
                    payout_limit   => formatnumber('amount', $currency, $limit_ref->{$_->risk_profile}{payout}{$currency}),
                    profile_name   => $_->risk_profile
                }
            } @submarket_list;
            push @{$limits{$market->name}}, @list;
        } else {
            push @{$limits{$market->name}},
                +{
                name           => $market->display_name,
                turnover_limit => formatnumber('amount', $currency, $limit_ref->{$market->risk_profile}{turnover}{$currency}),
                payout_limit   => formatnumber('amount', $currency, $limit_ref->{$market->risk_profile}{payout}{$currency}),
                profile_name   => $market->risk_profile,
                };
        }
    }

    return \%limits;
}

=head2 get_commission

Get commission set by quants from product management tool.

=cut

sub get_commission {
    my $self = shift;

    my @matched_commissions = map { $_->{commission} } grep { $self->_match_conditions($_) } @{$self->raw_custom_commission_profiles};

    return unless @matched_commissions;
    return max(@matched_commissions);
}

my %_no_condition;
@_no_condition{qw(name risk_profile updated_by updated_on non_binary_contract_limit commission)} = ();

sub _match_conditions {
    my ($self, $custom, $additional_info) = @_;

    $additional_info = {} unless defined $additional_info;
    my $real_tests_performed;
    my $ci = {%{$self->contract_info}, %$additional_info};

    foreach my $key (keys %$custom) {
        next if exists $_no_condition{$key};    # skip test
        $real_tests_performed = 1;
        next if exists $ci->{$key} and first { $ci->{$key} eq $_ } (split ',', $custom->{$key});    # match: continue with next condition
        return;                                                                                     # no match
    }

    return $real_tests_performed;                                                                   # all conditions match
}

sub _offerings_obj {
    my $landing_company_short = shift // 'costarica';
    my $country_code = shift;

    my $landing_company = LandingCompany::Registry::get($landing_company_short);

    if ($country_code) {
        my $method = $landing_company->default_offerings eq 'basic' ? 'basic_offerings_for_country' : 'multi_barrier_offerings_for_country';
        return $landing_company->$method($country_code, BOM::Config::Runtime->instance->get_offerings_config);
    } else {
        my $method = $landing_company->default_offerings eq 'basic' ? 'basic_offerings' : 'multi_barrier_offerings';
        return $landing_company->$method(BOM::Config::Runtime->instance->get_offerings_config);
    }
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

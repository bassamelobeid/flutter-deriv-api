package BOM::Product::RiskProfile;

use Moose;

use BOM::Platform::Runtime;
use BOM::Platform::Offerings qw(get_offerings_with_filter);
use BOM::Market::Underlying;
use Finance::Asset::Market::Registry;
use Finance::Asset::SubMarket::Registry;
use BOM::System::Config;

use JSON qw(from_json);

use constant RISK_PROFILES => [qw(no_business extreme_risk high_risk medium_risk low_risk)];

my %risk_profile_rank;
for (my $i = 0; $i < @{RISK_PROFILES()}; $i++) {
    $risk_profile_rank{RISK_PROFILES->[$i]} = $i;
}

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
                limit => $self->limits->{$_->{risk_profile}}{turnover}{$self->currency},
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

            if ($_->{market}) {
                $params->{symbols} = [map { {n => $_} } get_offerings_with_filter('underlying_symbol', {market => $_->{market}})];
            } elsif ($_->{submarket}) {
                $params->{symbols} = [map { {n => $_} } get_offerings_with_filter('underlying_symbol', {submarket => $_->{submarket}})];
            } elsif ($_->{underlying_symbol}) {
                $params->{symbols} = [{n => $_->{underlying_symbol}}];
            }

            if ($_->{contract_category}) {
                $params->{bet_type} =
                    [map { {n => $_} } get_offerings_with_filter('contract_type', {contract_category => $_->{contract_category}})];
            }

            $params;
            } @{$self->custom_profiles},
        @$ap
    ];
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

has custom_profiles => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_custom_profiles {
    my $self = shift;

    my @profiles = grep { $self->_match_conditions($_) } values %{$self->raw_custom_profiles};

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

# this is a cache to avoid from_json for each contract
my $custom_limits_txt      = '';
my $custom_limits_compiled = {};

sub get_client_profiles {
    my ($self, $client) = @_;

    if ($client) {
        my $loginid = $client->loginid;
        my $ptr     = \BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles;    # use a pointer to avoid copying
        $custom_limits_compiled = from_json($custom_limits_txt = $$ptr)                                 # copy and compile
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
        my $lcn                    = $client->landing_company->short;
        foreach my $custom (values %{$self->raw_custom_profiles}) {
            next unless exists $custom->{landing_company};
            next if $lcn ne $custom->{landing_company};
            push @landing_company_limits, $custom if $self->_match_conditions($custom, {landing_company => $lcn});
        }

        return (@client_limits, @landing_company_limits);
    }

    return;
}

sub get_current_profile_definitions {
    my $client = shift;

    my ($currency, $landing_company);
    if ($client) {
        ($currency, $landing_company) = ($client->currency, $client->landing_company->short);
    } else {
        # set some defaults here
        ($currency, $landing_company) = ('USD', 'costarica');
    }

    my @markets = map { Finance::Asset::Market::Registry->get($_) } get_offerings_with_filter('market', {landing_company => $landing_company});
    my $limit_ref = BOM::System::Config::quants->{risk_profile};

    my %limits;
    foreach my $market (@markets) {
        my @submarket_list =
            grep { $_->risk_profile }
            map { Finance::Asset::SubMarket::Registry->get($_) } get_offerings_with_filter('submarket', {market => $market->name});
        if (@submarket_list) {
            my @list = map { {
                    name           => $_->display_name,
                    turnover_limit => $limit_ref->{$_->risk_profile}{turnover}{$currency},
                    payout_limit   => $limit_ref->{$_->risk_profile}{payout}{$currency},
                    profile_name   => $_->risk_profile
                }
            } @submarket_list;
            push @{$limits{$market->name}}, @list;
        } else {
            push @{$limits{$market->name}},
                +{
                name           => $market->display_name,
                turnover_limit => $limit_ref->{$market->risk_profile}{turnover}{$currency},
                payout_limit   => $limit_ref->{$market->risk_profile}{payout}{$currency},
                profile_name   => $market->risk_profile,
                };
        }
    }

    return \%limits;
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


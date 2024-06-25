package BOM::Platform::Account::Real::maltainvest;

use strict;
use warnings;

use Encode;
use JSON::MaybeXS;
use Date::Utility;

use BOM::Platform::Account::Real::default;
use BOM::Platform::Email           qw(send_email);
use BOM::Platform::Context         qw(request);
use BOM::User::FinancialAssessment qw(should_warn update_financial_assessment);
use Business::Config::Country::Registry;

sub create_account {
    my $args = shift;
    my ($account_type, $from_client, $user, $country, $details, $params, $wallet) =
        @{$args}{'account_type', 'from_client', 'user', 'country', 'details', 'params', 'wallet'};

    my $accept_risk = $params->{accept_risk};
    my $should_warn = should_warn($params);

    my $register = BOM::Platform::Account::Real::default::create_account({
        user         => $user,
        details      => $details,
        from_client  => $from_client,
        account_type => $account_type,
        wallet       => $wallet,
    });
    return $register if ($register->{error});

    my $client = $register->{client};

    my $employment_status = $params->{employment_status} // '';

    if ($employment_status && ($employment_status eq 'Unemployed' || $employment_status eq 'Self-Employed')) {
        $params->{occupation} = $employment_status;
    }

    update_financial_assessment($client->user, $params, new_mf_client => 1);

    my $country_config = Business::Config::Country::Registry->new()->by_code($client->residence);
    my $signup_config  = {};

    $signup_config = $country_config->signup if $country_config;

    if ($params->{resident_self_declaration} && $signup_config->{self_declaration}) {
        $client->status->setnx('resident_self_declaration', 'SYSTEM', 'Client accepted residence self-declaration');
    }

    # after_register_client sub save client so no need to call it here
    if ($accept_risk) {
        $client->status->setnx('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
    } elsif (not $should_warn) {
        $client->status->setnx('financial_risk_approval', 'SYSTEM', 'Financial risk approved based on financial assessment score');
    }

    return $register;
}

1;

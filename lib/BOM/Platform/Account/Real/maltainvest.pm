package BOM::Platform::Account::Real::maltainvest;

use strict;
use warnings;

use Encode;
use JSON::MaybeXS;
use Date::Utility;

use BOM::Platform::Account::Real::default;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(request);
use BOM::User::FinancialAssessment qw(should_warn update_financial_assessment);

sub _validate {
    my $args = shift;
    if (my $error = BOM::Platform::Account::Real::default::validate($args)) {
        return $error;
    }

    # also allow MLT UK client to open MF account
    my $from_client = $args->{from_client};
    my $company = request()->brand->countries_instance->financial_company_for_country($from_client->residence) // '';
    return if ($company eq 'maltainvest' or ($from_client->residence eq 'gb' and $from_client->landing_company->short eq 'malta'));

    warn("maltainvest acc opening err: loginid:" . $from_client->loginid . " residence:" . $from_client->residence . " financial_company:$company");
    return {error => 'invalid'};
}

sub create_account {
    my $args = shift;
    my ($from_client, $user, $country, $details, $params) =
        @{$args}{'from_client', 'user', 'country', 'details', 'params'};

    my $accept_risk = $params->{accept_risk};

    if (my $error = _validate($args)) {
        return $error;
    }

    my $should_warn = should_warn($params);

    # show Risk disclosure warning if client haven't accepted risk yet and FA score matches warning conditions
    return {error => 'show risk disclaimer'} if !$accept_risk && $should_warn;

    my $register = BOM::Platform::Account::Real::default::create_account({
        user        => $user,
        details     => $details,
        from_client => $from_client
    });
    return $register if ($register->{error});

    my $client = $register->{client};
    update_financial_assessment($client->user, $params, new_mf_client => 1);

    # after_register_client sub save client so no need to call it here
    $client->status->set('unwelcome', 'SYSTEM', 'Trading disabled for investment Europe ltd');
    if ($accept_risk) {
        $client->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
    } elsif (not $should_warn) {
        $client->status->set('financial_risk_approval', 'SYSTEM', 'Financial risk approved based on financial assessment score');
    }

    BOM::Platform::Account::Real::default::add_details_to_desk($client, $details);

    return $register;
}

1;

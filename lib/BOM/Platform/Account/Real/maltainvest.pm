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

sub create_account {
    my $args = shift;
    my ($from_client, $user, $country, $details, $params) =
        @{$args}{'from_client', 'user', 'country', 'details', 'params'};

    my $accept_risk = $params->{accept_risk};

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

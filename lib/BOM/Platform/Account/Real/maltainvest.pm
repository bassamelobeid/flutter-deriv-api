package BOM::Platform::Account::Real::maltainvest;

use strict;
use warnings;

use JSON qw(encode_json);
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Account::Real::default;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Static::Config;

sub _validate {
    my $args = shift;
    if (my $error = BOM::Platform::Account::Real::default::_validate($args)) {
        return $error;
    }

    # also allow MLT UK client to open MF account
    my $from_client = $args->{from_client};
    my $company = BOM::Platform::Runtime->instance->financial_company_for_country($from_client->residence) // '';
    return if ($company eq 'maltainvest' or ($from_client->residence eq 'gb' and $from_client->landing_company->short eq 'malta'));

    get_logger()
        ->warn(
        "maltainvest acc opening err: loginid:" . $from_client->loginid . " residence:" . $from_client->residence . " financial_company:$company");
    return {error => 'invalid'};
}

sub create_account {
    my $args = shift;
    my ($from_client, $user, $country, $details, $financial_data, $accept_risk) =
        @{$args}{'from_client', 'user', 'country', 'details', 'financial_data', 'accept_risk'};

    if (my $error = _validate($args)) {
        return $error;
    }

    my $financial_assessment = BOM::Platform::Account::Real::default::get_financial_assessment_score($financial_data);
    if (not $accept_risk and $financial_assessment->{total_score} < 60) {
        return {error => 'show risk disclaimer'};
    }

    my $register = BOM::Platform::Account::Real::default::_register_client($details);
    return $register if ($register->{error});

    my $client = $register->{client};
    $client->financial_assessment({
        data            => encode_json($financial_assessment->{user_data}),
        is_professional => $financial_assessment->{total_score} < 60 ? 0 : 1,
    });
    $client->set_status('unwelcome', 'SYSTEM', 'Trading disabled for investment Europe ltd');
    $client->save;

    my $status = BOM::Platform::Account::Real::default::_after_register_client({
        client  => $client,
        user    => $user,
        details => $details,
    });

    if ($financial_assessment->{total_score} > 59) {
        send_email({
            from    => BOM::Platform::Static::Config::get_customer_support_email(),
            to      => BOM::Platform::Runtime->instance->app_config->compliance->email,
            subject => $client->loginid . ' considered as professional trader',
            message =>
                [$client->loginid . ' scored ' . $financial_assessment->{total_score} . ' and is therefore considered a professional trader.'],
        });
    }
    return $status;
}

1;

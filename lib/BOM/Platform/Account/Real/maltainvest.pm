package BOM::Platform::Account::Real::maltainvest;

use strict;
use warnings;

use JSON qw(encode_json);
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Account::Real::default;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Email qw(send_email);

sub _validate {
    my $args  = shift;
    if (my $error = BOM::Platform::Account::Real::default::_validate($args)) {
        return $error;
    }

    # also allow MLT UK client to open MF account
    my $from_client = $args->{from_client};
    my $company = BOM::Platform::Runtime->instance->financial_company_for_country($from_client->residence) // '';
    return if ($company eq 'maltainvest' or ($from_client->residence eq 'gb' and $from_client->landing_company->short eq 'malta'));

    get_logger()->warn("maltainvest acc opening err: loginid:" . $from_client->loginid . " residence:" . $from_client->residence . " financial_company:$company");
    return { error => 'invalid' };
}

sub create_account {
    my $args = shift;
    my ($from_client, $user, $country, $details, $financial_evaluation) = @{$args}{'from_client', 'user', 'country', 'details', 'financial_evaluation'};

    if (my $error = _validate($args)) {
        return $error;
    }
    my $register = BOM::Platform::Account::Real::default::_register_client($details);
    return $register if ($register->{error});

    my $client = $register->{client};
    $client->financial_assessment({
        data            => encode_json($financial_evaluation->{user_data}),
        is_professional => $financial_evaluation->{total_score} < 60 ? 0 : 1,
    });
    $client->set_status('unwelcome', 'SYSTEM', 'Trading disabled for investment Europe ltd');
    $client->save;

    my $status = BOM::Platform::Account::Real::default::_after_register_client({
        client => $client,
        user   => $user,
    });

    if ($financial_evaluation->{total_score} > 59) {
        send_email({
            from    => request()->website->config->get('customer_support.email'),
            to      => BOM::Platform::Runtime->instance->app_config->compliance->email,
            subject => $client->loginid . ' considered as professional trader',
            message =>
                [$client->loginid . ' scored ' . $financial_evaluation->{total_score} . ' and is therefore considered a professional trader.'],
        });
    }
    return $status;
}

1;

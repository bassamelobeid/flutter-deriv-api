package BOM::Platform::Account::Real::maltainvest;

use strict;
use warnings;

use JSON::MaybeXS;
use Date::Utility;

use Brands;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(request);

sub _validate {
    my $args = shift;
    if (my $error = BOM::Platform::Account::Real::default::validate($args)) {
        return $error;
    }

    # also allow MLT UK client to open MF account
    my $from_client = $args->{from_client};
    my $company = Brands->new(name => request()->brand)->countries_instance->financial_company_for_country($from_client->residence) // '';
    return if ($company eq 'maltainvest' or ($from_client->residence eq 'gb' and $from_client->landing_company->short eq 'malta'));

    warn("maltainvest acc opening err: loginid:" . $from_client->loginid . " residence:" . $from_client->residence . " financial_company:$company");
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

    my $register = BOM::Platform::Account::Real::default::register_client($details);
    return $register if ($register->{error});

    my $client = $register->{client};
    $client->financial_assessment({
        data            => $json->encode($financial_assessment->{user_data}),
        is_professional => $financial_assessment->{total_score} < 60 ? 0 : 1,
    });
    $client->set_status('unwelcome', 'SYSTEM', 'Trading disabled for investment Europe ltd');
    # this will be always true as max score client can get is less than 60
    # but to be on safer side for future added if condition
    $client->set_status('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure') if $accept_risk;
    $client->save;

    my $status = BOM::Platform::Account::Real::default::after_register_client({
        client      => $client,
        user        => $user,
        details     => $details,
        from_client => $from_client,
        ip          => $args->{ip},
        country     => $args->{country},
    });

    set_crs_tin_status($client, 1);

    BOM::Platform::Account::Real::default::add_details_to_desk($client, $details);

    if ($financial_assessment->{total_score} > 59) {
        my $brand = Brands->new(name => request()->brand);
        send_email({
            from    => $brand->emails('support'),
            to      => $brand->emails('compliance'),
            subject => $client->loginid . ' considered as professional trader',
            message =>
                [$client->loginid . ' scored ' . $financial_assessment->{total_score} . ' and is therefore considered a professional trader.'],
        });
    }
    return $status;
}

# As per CRS/FATCA regulatory requirement we need to save this information as client status
# All previous update dates can be obtained from audit logs.
sub set_crs_tin_status {
    my ($client, $is_save) = @_;

    my $data = Date::Utility->new()->date;

    # update status with new date
    $client->set_status('crs_tin_information', 'system', $data);
    $client->save if $is_save;

    return;
}

1;

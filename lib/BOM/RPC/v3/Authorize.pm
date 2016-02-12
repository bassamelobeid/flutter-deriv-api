package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use Date::Utility;

use BOM::System::AuditLog;
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Context qw (localize request);
use BOM::RPC::v3::Utility;

sub authorize {
    my $params = shift;

    my $err = BOM::RPC::v3::Utility::invalid_token_error();

    my $loginid = BOM::RPC::v3::Utility::token_to_loginid $params->{token};
    return $err unless $loginid;

    my $client = BOM::Platform::Client->new({loginid => $loginid});
    return $err unless $client;

    my $account = $client->default_account;

    return {
        fullname             => $client->full_name,
        loginid              => $client->loginid,
        balance              => ($account ? $account->balance : 0),
        currency             => ($account ? $account->currency_code : ''),
        email                => $client->email,
        account_id           => ($account ? $account->id : ''),
        landing_company_name => $client->landing_company->short,
        country              => $client->residence
    };
}

sub logout {
    my $params = shift;

    my $email   = $params->{client_email}   // '';
    my $loginid = $params->{client_loginid} // '';

    if ($email) {
        if (my $user = BOM::Platform::User->new({email => $email})) {
            $user->add_login_history({
                environment => _login_env($params),
                successful  => 't',
                action      => 'logout',
            });
            $user->save;
        }
        BOM::System::AuditLog::log("user logout", "$email,$loginid");
    }

    return {status => 1};
}

sub _login_env {
    my $params = shift;

    my $now                = Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ;
    my $ip_address         = $params->{client_ip} || '';
    my $ip_address_country = uc $params->{country_code} || '';
    my $lang               = uc $params->{language} || '';
    my $ua                 = $params->{user_agent} || '';
    my $environment        = "$now IP=$ip_address IP_COUNTRY=$ip_address_country User_AGENT=$ua LANG=$lang";
    return $environment;
}

1;

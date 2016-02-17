package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use Date::Utility;

use BOM::System::AuditLog;
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use BOM::Platform::Context qw (localize request);
use BOM::Database::Model::AccessToken;
use BOM::Database::Model::OAuth;
use BOM::RPC::v3::Utility;

sub authorize {
    my $params = shift;

    my $err = BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidToken',
            message_to_client => BOM::Platform::Context::localize('The token is invalid.')});

    my $loginid;
    my $token = $params->{token};
    if (length $token == 15) {    # access token
        my $m = BOM::Database::Model::AccessToken->new;
        $loginid = $m->get_loginid_by_token($token);
        return $err unless $loginid;
    } elsif (length $token == 32 && $token =~ /^a1-/) {
        my $m = BOM::Database::Model::OAuth->new;
        $loginid = $m->get_loginid_by_access_token($token);
        return $err unless $loginid;
    } else {
        my $session = BOM::Platform::SessionCookie->new(token => $token);
        if (!$session || !$session->validate_session()) {
            return $err;
        }
        $loginid = $session->loginid;
    }

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
        country              => $client->residence,
        is_virtual           => ($client->is_virtual ? 1 : 0),
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

package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use Date::Utility;

use BOM::System::AuditLog;
use BOM::RPC::v3::Utility;
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::SessionCookie;

sub authorize {
    my $params = shift;

    my $loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $loginid;

    my $client = BOM::Platform::Client->new({loginid => $loginid});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client;

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

    if (my $email = $params->{client_email}) {
        my $loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token}) // '';
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

    # Invalidates token, but we can only do this if we have a session token
    if ($params->{token_type} eq 'session_token') {
        my $session = BOM::Platform::SessionCookie->new({token => $params->{token}});
        $session->end_session if $session;
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

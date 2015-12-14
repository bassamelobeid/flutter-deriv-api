package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use BOM::RPC::v3::Utility;

use Date::Utility;
use BOM::System::AuditLog;
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use BOM::Platform::Context qw (localize);
use BOM::Database::Model::AccessToken;

sub authorize {
    my $token = shift;

    my $err = BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidToken',
            message_to_client => BOM::Platform::Context::localize('The token is invalid.')});

    my $loginid;
    if (length $token == 15) {    # access token
        my $m = BOM::Database::Model::AccessToken->new;
        $loginid = $m->get_loginid_by_token($token);
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
        fullname => $client->full_name,
        loginid  => $client->loginid,
        balance  => ($account ? $account->balance : 0),
        currency => ($account ? $account->currency_code : ''),
        email    => $client->email,
    };
}

sub logout {
    my ($r, $ua) = @_;

    my $email   = $r->email   // '';
    my $loginid = $r->loginid // '';

    # Invalidates token, but we can only do this if we have a cookie
    $r->session_cookie->end_session if $r->session_cookie;

    if ($email) {
        if (my $user = BOM::Platform::User->new({email => $email})) {
            $user->add_login_history({
                environment => login_env($r, $ua),
                successful  => 't',
                action      => 'logout',
            });
            $user->save;
        }
        BOM::System::AuditLog::log("user logout", "$email,$loginid");
    }
}

sub login_env {
    my ($r, $ua) = @_;

    my $now                = Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ;
    my $ip_address         = $r->client_ip || '';
    my $ip_address_country = uc $r->country_code || '';
    my $lang               = uc $r->language || '';
    my $environment        = "$now IP=$ip_address IP_COUNTRY=$ip_address_country User_AGENT=$ua LANG=$lang";
    return $environment;
}

1;

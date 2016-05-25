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

    my $token         = $params->{token};
    my $token_details = $params->{token_details};
    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my ($loginid, $scopes) = @{$token_details}{qw/loginid scopes/};

    my $client = BOM::Platform::Client->new({loginid => $loginid});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client;

    if ($client->get_status('disabled')) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'AccountDisabled',
                message_to_client => BOM::Platform::Context::localize("Account is disabled.")});
    }

    if ($client->get_self_exclusion and $client->get_self_exclusion->exclude_until) {
        my $limit_excludeuntil = $client->get_self_exclusion->exclude_until;
        if (Date::Utility->new->is_before(Date::Utility->new($limit_excludeuntil))) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'SelfExclusion',
                    message_to_client => BOM::Platform::Context::localize("Sorry, you have excluded yourself until [_1].", $limit_excludeuntil)});
        }
    }

    my $account = $client->default_account;

    my $token_type = 'session_token';
    if (length $token == 15) {
        $token_type = 'api_token';
    } elsif (length $token == 32 && $token =~ /^a1-/) {
        $token_type = 'oauth_token';
    }

    return {
        fullname             => $client->full_name,
        loginid              => $client->loginid,
        balance              => ($account ? $account->balance : 0),
        currency             => ($account ? $account->currency_code : ''),
        email                => $client->email,
        landing_company_name => $client->landing_company->short,
        scopes               => $scopes,
        is_virtual           => ($client->is_virtual ? 1 : 0),
        stash                => {
            loginid              => $client->loginid,
            email                => $client->email,
            token                => $token,
            token_type           => $token_type,
            scopes               => $scopes,
            account_id           => ($account ? $account->id : ''),
            country              => $client->residence,
            currency             => ($account ? $account->currency_code : ''),
            landing_company_name => $client->landing_company->short,
            is_virtual           => ($client->is_virtual ? 1 : 0),
        },
    };
}

sub logout {
    my $params = shift;

    if (my $email = $params->{email}) {
        my $token_details = $params->{token_details};
        my $loginid = ($token_details and exists $token_details->{loginid}) ? $token_details->{loginid} : '';
        if (my $user = BOM::Platform::User->new({email => $email})) {
            $user->add_login_history({
                environment => _login_env($params),
                successful  => 't',
                action      => 'logout',
            });
            $user->save;

            if ($params->{token_type} eq 'oauth_token') {
                # revoke tokens for user per app_id
                my $oauth  = BOM::Database::Model::OAuth->new;
                my $app_id = $oauth->get_app_id_by_token($params->{token});

                foreach my $c1 ($user->clients) {
                    $oauth->revoke_tokens_by_loginid_app($c1->loginid, $app_id);
                }
            }
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

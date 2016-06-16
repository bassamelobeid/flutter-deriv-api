package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use Date::Utility;

use BOM::System::AuditLog;
use BOM::RPC::v3::Utility;
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Context qw (localize request);

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

    my $token_type;
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
        my ($loginid, $scopes) = ($token_details and exists $token_details->{loginid}) ? @{$token_details}{qw/loginid scopes/} : ();

        if (my $user = BOM::Platform::User->new({email => $email})) {
            my $skip_login_history;

            if ($params->{token_type} eq 'oauth_token') {
                # revoke tokens for user per app_id
                my $oauth  = BOM::Database::Model::OAuth->new;
                my $app_id = $oauth->get_app_id_by_token($params->{token});

                # need to skip as we impersonate from backoffice using read only token
                $skip_login_history = 1 if ($scopes and scalar(@$scopes) == 1 and $scopes->[0] eq 'read');

                foreach my $c1 ($user->clients) {
                    $oauth->revoke_tokens_by_loginid_app($c1->loginid, $app_id);
                }
            }

            unless ($skip_login_history) {
                $params->{country} = $params->{country_code} if $params->{country_code};
                $user->add_login_history({
                    environment => BOM::RPC::v3::Utility::login_env($params),
                    successful  => 't',
                    action      => 'logout',
                });
                $user->save;
                BOM::System::AuditLog::log("user logout", join(',', $email, $loginid // ''));
            }
        }
    }
    return {status => 1};
}

1;

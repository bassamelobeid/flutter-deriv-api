package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use Date::Utility;

use Client::Account;
use Format::Util::Numbers qw/formatnumber/;

use BOM::Platform::AuditLog;
use BOM::RPC::v3::Utility;
use BOM::Platform::User;
use BOM::Platform::Context qw (localize request);
use BOM::RPC::v3::Utility;

sub authorize {
    my $params = shift;
    my ($token, $token_details, $client_ip) = @{$params}{qw/token token_details client_ip/};

    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});
    # temorary remove ua_fingerptint check
    #if ($token_details->{ua_fingerprint} && $token_details->{ua_fingerprint} ne $params->{ua_fingerprint}) {
    #    return BOM::RPC::v3::Utility::invalid_token_error();
    #}

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidToken',
            message_to_client => BOM::Platform::Context::localize("Token is not valid for current ip address.")}
    ) if (exists $token_details->{valid_for_ip} and $token_details->{valid_for_ip} ne $client_ip);

    my ($loginid, $scopes) = @{$token_details}{qw/loginid scopes/};

    my $client = Client::Account->new({
        loginid      => $loginid,
        db_operation => 'replica'
    });
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client;

    my ($lc, $brand_name) = ($client->landing_company, request()->brand);
    # check for not allowing cross brand tokens
    return BOM::RPC::v3::Utility::invalid_token_error() unless (grep { $brand_name eq $_ } @{$lc->allowed_for_brands});

    if ($client->get_status('disabled')) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'AccountDisabled',
                message_to_client => BOM::Platform::Context::localize("Account is disabled.")});
    }

    if (my $limit_excludeuntil = $client->get_self_exclusion_until_dt) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'SelfExclusion',
                message_to_client => BOM::Platform::Context::localize("Sorry, you have excluded yourself until [_1].", $limit_excludeuntil)});
    }

    my ($user, $token_type) = (BOM::Platform::User->new({email => $client->email}));
    if (length $token == 15) {
        $token_type = 'api_token';
        # add to login history for api token only as oauth login already creates an entry
        if ($params->{args}->{add_to_login_history} && $user) {
            $user->add_login_history({
                environment => BOM::RPC::v3::Utility::login_env($params),
                successful  => 't',
                action      => 'login',
            });
            $user->save;
        }
    } elsif (length $token == 32 && $token =~ /^a1-/) {
        $token_type = 'oauth_token';
    }

    my (@sub_accounts, @accounts) = ((), ());
    my ($is_omnibus, $currency) = ($client->allow_omnibus);

    my $siblings = $user->loginid_details;

    # need to sort so that virtual is last one
    foreach my $key (sort keys %$siblings) {
        my $account = Client::Account->new({
            loginid      => $key,
            db_operation => 'replica'
        });

        next if not $account or $account->get_status('duplicate_account');

        $currency = $account->default_account ? $account->default_account->currency_code : '';
        if ($is_omnibus and $loginid eq ($account->sub_account_of // '')) {
            push @sub_accounts,
                {
                loginid  => $account->loginid,
                currency => $currency,
                };
        }

        my ($self_exclusion, $self_exclusion_epoch, $until);
        if ($self_exclusion = $account->get_self_exclusion and $until = ($self_exclusion->timeout_until // $self_exclusion->exclude_until)) {
            $self_exclusion_epoch = Date::Utility->new($until)->epoch if Date::Utility->new($until)->is_after(Date::Utility->new);
        }

        push @accounts,
            {
            loginid              => $account->loginid,
            currency             => $currency,
            landing_company_name => $account->landing_company->short,
            is_disabled          => $account->get_status('disabled') ? 1 : 0,
            is_ico_only          => $account->get_status('ico_only') ? 1 : 0,
            is_virtual           => $account->is_virtual ? 1 : 0,
            $self_exclusion_epoch ? (excluded_until => $self_exclusion_epoch) : ()};
    }

    my $account = $client->default_account;
    return {
        fullname => $client->full_name,
        loginid  => $client->loginid,
        balance  => $account ? formatnumber('amount', $account->currency_code, $account->balance) : '0.00',
        currency => ($account ? $account->currency_code : ''),
        email    => $client->email,
        country  => $client->residence,
        landing_company_name     => $lc->short,
        landing_company_fullname => $lc->name,
        scopes                   => $scopes,
        is_virtual               => $client->is_virtual ? 1 : 0,
        allow_omnibus            => $client->allow_omnibus ? 1 : 0,
        account_list             => \@accounts,
        sub_accounts             => \@sub_accounts,
        stash                    => {
            loginid              => $client->loginid,
            email                => $client->email,
            token                => $token,
            token_type           => $token_type,
            scopes               => $scopes,
            account_id           => ($account ? $account->id : ''),
            country              => $client->residence,
            currency             => ($account ? $account->currency_code : ''),
            landing_company_name => $lc->short,
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

                unless ($skip_login_history) {
                    $user->add_login_history({
                        environment => BOM::RPC::v3::Utility::login_env($params),
                        successful  => 't',
                        action      => 'logout',
                    });
                    $user->save;
                    BOM::Platform::AuditLog::log("user logout", join(',', $email, $loginid // ''));
                }
            }
        }
    }
    return {status => 1};
}

1;

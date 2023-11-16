package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use Date::Utility;
use List::Util qw(uniq any none);
use Convert::Base32;
use Format::Util::Numbers qw/formatnumber/;

use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Annotations qw(annotate_db_calls);
use BOM::RPC::v3::Accounts;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Token::API;
use BOM::User;
use BOM::User::AuditLog;
use BOM::User::Client;
use BOM::User::TOTP;
use BOM::Config::Runtime;
use BOM::Config::AccountType::Registry;

use LandingCompany::Registry;

rpc authorize => sub {
    my $params = shift;
    my ($token, $token_details, $client_ip) = @{$params}{qw/token token_details client_ip/};

    return BOM::RPC::v3::Utility::suspended_login() if BOM::Config::Runtime->instance->app_config->system->suspend->all_logins;

    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my $account_tokens_result = _get_account_tokens($params, $token, $token_details, $client_ip);
    return $account_tokens_result->{error} if $account_tokens_result->{status} == 0;
    my $account_tokens = $account_tokens_result->{result};

    my ($loginid, $scopes) = @{$token_details}{qw/loginid scopes/};

    my $client = BOM::User::Client->get_client_instance($loginid, 'replica');
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client;

    my $user = $client->user;
    $user->setnx_preferred_language($params->{language}) if $params->{language} && $params->{language} =~ /^[A-Z]{2}$|^[A-Z]{2}_[A-Z]{2}$/i;

    $params->{app_id} = $params->{source};

    my ($lc, $brand_name) = ($client->landing_company, request()->brand->name);

    # check for not allowing cross brand tokens
    return BOM::RPC::v3::Utility::invalid_token_error() unless (grep { $brand_name eq $_ } @{$lc->allowed_for_brands});

    # Tokens in account_tokens are verified in sub _valid_loginids_for_user
    unless ($client->is_available) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'AccountDisabled',
                message_to_client => BOM::Platform::Context::localize("Account is disabled.")});
    }

    my $account_links = $user->get_accounts_links();
    my $clients       = _get_clients($user);
    my $account_list  = _get_account_list($clients, $account_links);
    _add_details_to_account_token_list($account_list, $account_tokens);

    unless (_valid_loginids_for_user($account_list, [keys $account_tokens->%*])) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => BOM::Platform::Context::localize("Token is not valid for current user.")});
    }

    my $token_type;
    if (_is_api_token($token)) {
        $token_type = _handle_api_token($params, $user);
    } elsif (_is_oauth_token($token)) {
        $token_type = _handle_oauth_tokens($params, $account_tokens, $clients, $user);
    }

    unless ($token_type) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => BOM::Platform::Context::localize("Token is not valid for current app ID.")});
    }

    my $local_currencies = _get_client_local_currencies($client);

    my $account = $client->default_account;

    my @upgradeable_companies = get_client_upgradeable_landing_companies($client);

    return {
        fullname                      => $client->full_name,
        user_id                       => $client->binary_user_id,
        loginid                       => $client->loginid,
        balance                       => $account ? formatnumber('amount', $account->currency_code(), $account->balance) : '0.00',
        currency                      => ($account ? $account->currency_code() : ''),
        local_currencies              => $local_currencies,
        email                         => $client->email,
        country                       => $client->residence,
        landing_company_name          => $lc->short,
        landing_company_fullname      => $lc->name,
        linked_to                     => $account_links->{$client->loginid} // [],
        preferred_language            => $user->preferred_language,
        scopes                        => $scopes,
        is_virtual                    => $client->is_virtual ? 1 : 0,
        upgradeable_landing_companies => \@upgradeable_companies,
        account_list                  => $account_list,
        stash                         => {
            loginid              => $client->loginid,
            email                => $client->email,
            token                => $token,
            account_tokens       => $account_tokens,
            token_type           => $token_type,
            scopes               => $scopes,
            account_id           => ($account ? $account->id : ''),
            country              => $client->residence,
            currency             => ($account ? $account->currency_code() : ''),
            landing_company_name => $lc->short,
            is_virtual           => ($client->is_virtual ? 1 : 0),
            broker               => $client->broker,
        },
    };
};

=head2 _get_account_tokens

    $result = _get_account_tokens($params, $token, $token_details, $client_ip)

Returns an hash of loginid with token for each token provided in the request (tokens+authorize).

=over 4

=item * - C<params> - RPC params

=item * - C<token> - token from the authorize request

=item * - C<token_details> - token details from the authorize request

=item * - C<client_ip> - client ip address

=back

=cut

sub _get_account_tokens {
    my ($params, $token, $token_details, $client_ip) = @_;

    my $account_tokens_details_result = _get_all_token_details_by_loginid($params, $token, $token_details);
    return $account_tokens_details_result if $account_tokens_details_result->{status} == 0;
    my $account_tokens_details = $account_tokens_details_result->{result};

    my $token_error = _verify_tokens($account_tokens_details, $client_ip);
    return {
        status => 0,
        error  => $token_error
    } if $token_error;

    my %account_tokens = map { $_ => {token => $account_tokens_details->{$_}{token}} } keys $account_tokens_details->%*;
    return {
        status => 1,
        result => \%account_tokens
    };
}

=head2 _get_all_token_details_by_loginid

    @tokens_loginids = _get_all_token_details_by_loginid($params, $auth_token, $token_details)

Returns an hash of loginid with token and details for each token provided in the request (tokens+authorize).

=over 4

=item * - C<params> - RPC params

=item * - C<auth_token> - token from the authorize request

=item * - C<token_details> - token details from the authorize request

=back

=cut

sub _get_all_token_details_by_loginid {
    my ($params, $auth_token, $token_details) = @_;

    my %tokens_details = ();
    $tokens_details{$token_details->{loginid}} = $token_details;
    $tokens_details{$token_details->{loginid}}{token} = $auth_token;

    if (!$params->{args}->{tokens}) {
        return {
            status => 1,
            result => \%tokens_details
        };
    }

    my $token_instance = BOM::Platform::Token::API->new;
    foreach my $token ($params->{args}->{tokens}->@*) {
        my $detail = $token_instance->get_client_details_from_token($token);

        my $error;
        if (!$detail) {
            $error = BOM::RPC::v3::Utility::create_error({
                    code              => 'InvalidToken',
                    message_to_client => BOM::Platform::Context::localize("Token doesn't exist.")});
        } elsif (exists $tokens_details{$detail->{loginid}}) {
            $error = BOM::RPC::v3::Utility::create_error({
                    code              => 'InvalidToken',
                    message_to_client => BOM::Platform::Context::localize("Duplicate token for loginid.")});
        }

        if ($error) {
            return {
                status => 0,
                error  => $error
            };
        }

        $detail->{token} = $token;
        $tokens_details{$detail->{loginid}} = $detail;
    }

    return {
        status => 1,
        result => \%tokens_details
    };
}

=head2 _verify_tokens

    $token_error = _verify_tokens($tokens_details, $client_ip)

Returns error if loginid is disabled or not valid for user.

=over 4

=item * - C<tokens_details> - hash containing all the tokens and details

=item * - C<client_ip> - client ip address

=back

=cut

sub _verify_tokens {
    my ($tokens_details, $client_ip) = @_;

    my @tokens_loginids = keys $tokens_details->%*;
    foreach my $loginid (@tokens_loginids) {
        my $valid_for_ip = $tokens_details->{$loginid}{valid_for_ip};

        if (grep { $loginid =~ /^\Q$_/ } BOM::Config::Runtime->instance->app_config->system->suspend->logins->@*) {
            return BOM::RPC::v3::Utility::suspended_login();
        }

        if ($valid_for_ip and $valid_for_ip ne $client_ip) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InvalidToken',
                    message_to_client => BOM::Platform::Context::localize("Token is not valid for current ip address.")});
        }
    }

    if (@tokens_loginids > 1) {
        if (any { !_is_oauth_token($tokens_details->{$_}{token}) } @tokens_loginids) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InvalidToken',
                    message_to_client => BOM::Platform::Context::localize("API tokens can't be used to authorize multiple accounts.")});
        }
    }

    return undef;
}

=head2 _add_details_to_account_token_list

    _add_details_to_account_token_list($account_list, $account_tokens)

Sets the account_tokens  when the loginids given are associated with the user in the account_list and current loginid.

=over 4

=item * - C<account_list> - list of accounts of the user

=item * - C<account_tokens> - hash containing all the tokens and details

=back

=cut

sub _add_details_to_account_token_list {
    my ($account_list, $account_tokens) = @_;

    for my $account ($account_list->@*) {
        if ($account_tokens->{$account->{loginid}}) {
            my $token_details = $account_tokens->{$account->{loginid}};
            $token_details->{is_virtual} = $account->{is_virtual};
            $token_details->{broker}     = $account->{broker};
        }
        delete $account->{broker};
    }
}

=head2 _valid_loginids_for_user

    _valid_loginids_for_user($account_list, @tokens_loginids)

Returns true when the loginids given are associated with the user in the account_list.

=over 4

=item * - C<account_list> - list of accounts of the user

=item * - C<tokens_loginids> - list of loginids from the tokens provided in the authorize request.

=back

=cut

sub _valid_loginids_for_user {
    my ($account_list, $tokens_loginids) = @_;

    my %user_logins = map { $_->{loginid} => 1 } $account_list->@*;
    return none { !$user_logins{$_} } $tokens_loginids->@*;
}

=head2 _is_oauth_token

    $is_oauth_token = _is_oauth_token($token)

Returns true if the token is an OAuth token.

=over 4

=item * - C<token> - token from the authorize request

=back

=cut

sub _is_oauth_token {
    my ($token) = @_;
    return length $token == 32 && $token =~ /^a1-/;
}

=head2 _is_api_token

    $is_api_token = _is_api_token($token)

Returns true if the token is an api token.

=over 4

=item * - C<token> - token from the authorize request

=back

=cut

sub _is_api_token {
    my ($token) = @_;
    return length $token == 15;
}

=head2 _handle_api_token

    $token_type = _handle_api_token($params, $user)

Sets token_type and adds an entry to login history if add_to_login_history is set.


=over 4

=item * - C<params> - RPC params

=item * - C<user> - the L<BOM::User> instance

=back

=cut

sub _handle_api_token {
    my ($params, $user) = @_;

    if ($params->{args}->{add_to_login_history} && $user) {
        $user->add_login_history(
            environment => request()->login_env($params),
            successful  => 't',
            action      => 'login',
            app_id      => $params->{app_id});
    }

    return 'api_token';
}

=head2 _handle_oauth_tokens

    $token_type = _handle_oauth_tokens($params, $client);

Sets token_type and adds an entry to login history if add_to_login_history is set.
Additional check on app_id if it's valid or a login from the backoffice.

=over 4

=item * - C<params> - RPC params

=item * - C<account_tokens> - account_tokens hash

=item * - C<client> - the L<BOM::User::Client> instance

=back

=cut

sub _handle_oauth_tokens {
    my ($params, $account_tokens, $clients, $user) = @_;

    my $oauth    = BOM::Database::Model::OAuth->new;
    my @loginids = keys $account_tokens->%*;

    # Get extracted app_id. All must be the same.
    # TODO: Make this 1 query
    my $token_extracted_app_id = $oauth->get_app_id_by_token($account_tokens->{(keys %$account_tokens)[0]}{token});
    return undef unless $token_extracted_app_id;
    return undef if grep { ($oauth->get_app_id_by_token($_->{token}) // '') ne $token_extracted_app_id } values %$account_tokens;

    my $is_from_backoffice = $token_extracted_app_id eq '4';
    if ($is_from_backoffice) {
        return undef if @loginids > 1;    # Only allow one token when this is a backoffice login

        $user->add_login_history(
            environment => request()->login_env($params),
            successful  => 't',
            action      => 'login',
            app_id      => $token_extracted_app_id,
            token       => $params->{token});
    } else {
        return undef unless valid_shared_token($oauth, $params->{app_id}, $token_extracted_app_id);

        my %client_list = map { $_->loginid => $_ } $clients->@*;

        for my $loginid (@loginids) {
            my $client = $client_list{$loginid};
            if ($client->landing_company->ip_check_required) {
                BOM::RPC::v3::Utility::check_ip_country(
                    client_residence => $client->{residence},
                    client_ip        => $params->{client_ip},
                    country_code     => $params->{country_code},
                    client_login_id  => $loginid,
                    broker_code      => $client->{broker_code});
            }
        }
    }

    return 'oauth_token';
}

=head2 get_client_upgradeable_landing_companies

    @upgradeable_companies = get_client_upgradeable_landing_companies($client)

Gets a list of upgradeable companies for the client.

=over 4

=item * - C<client> - the L<BOM::User::Client> instance

=back

=cut

sub get_client_upgradeable_landing_companies {
    my ($client) = @_;

    # this field only for legacy accounts in future we'll use separate API call for returning this information
    return () unless $client->is_legacy;

    my %upgradeable_landing_companies = ();

    my $countries_instance = request()->brand->countries_instance;

    # Get the gaming and financial company from the client's residence
    my $gaming_company    = $countries_instance->gaming_company_for_country($client->residence)    // '';
    my $financial_company = $countries_instance->financial_company_for_country($client->residence) // '';

    my @siblings = values $client->real_account_siblings_information(
        exclude_disabled_no_currency => 1,
        include_self                 => 1
    )->%*;
    my $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        siblings        => {$client->loginid => \@siblings},
        stop_on_failure => 0
    );

    for my $lc (uniq($gaming_company, $financial_company)) {
        next unless $lc;

        # check account limits
        my $is_upgradeable = !$rule_engine->apply_rules(
            [qw/landing_company.accounts_limit_not_reached/],
            loginid         => $client->loginid,
            landing_company => $lc,
            account_type    => $client->get_account_type->name,
            stop_on_failure => 0
        )->has_failure;

        my @available_currencies;
        my %currency_hash = map { $_ => 0 } (keys LandingCompany::Registry->by_name($lc)->legal_allowed_currencies->%*);

        for my $currency (keys %currency_hash) {
            next
                if $rule_engine->apply_rules(
                [qw/landing_company.currency_is_allowed currency.is_available_for_new_account currency.is_currency_suspended/],
                loginid         => $client->loginid,
                landing_company => $lc,
                currency        => $currency,
                account_type    => $client->get_account_type->name,
            )->has_failure;

            push @available_currencies, $currency;
            $currency_hash{$currency} = 1;
        }

        # landing company is not upgradeable if there is no currency left
        $is_upgradeable = 0 unless scalar @available_currencies;

        $upgradeable_landing_companies{$lc} = {
            is_upgradeable       => $is_upgradeable,
            available_currencies => \%currency_hash
        };
    }

    my @upgradeable_companies = grep { $upgradeable_landing_companies{$_}->{is_upgradeable} } sort keys %upgradeable_landing_companies;

    return @upgradeable_companies;
}

=head2 _get_clients

    $clients = _get_clients($user)

Gets a list of valid clients of the user in a sorted order (real/virtual, active/inactive, sorted by loginid)

=over 4

=item * - C<user> - the L<BOM::User> instance

=back

=cut

sub _get_clients {
    my ($user) = @_;

    my $all_clients = $user->get_clients_in_sorted_order;

    # Return a client if:
    # its a virtual account
    # or selected account currency
    # or not disabled
    # is a regulated (EU) disabled account (disabled or enabled)
    my @clients = grep { $_->is_virtual || $_->account || !$_->status->disabled || $_->landing_company->is_eu } @$all_clients;
    return \@clients;

}

=head2 _get_account_list

    $account_list = _get_account_list($user, $account_links)

Gets a list of valid accounts of the user.

=over 4

=item * - C<user> - the L<BOM::User> instance

=item * - account_links - hash containing all the accounts of the user

=back

=cut

sub _get_account_list {
    my ($clients, $account_links) = @_;

    my @account_list;
    for my $cli ($clients->@*) {
        my $details = $cli->get_account_details;
        $details->{broker}    = $cli->broker;
        $details->{linked_to} = $account_links->{$cli->loginid} // [];
        push @account_list, $details;
    }

    return \@account_list;
}

=head2 _get_client_local_currencies

    $local_currencies = _get_client_local_currencies($client)

    List of local currencies for the client with precision

=over 4

=item * - C<client> - the L<BOM::User::Client> instance

=back

=cut

sub _get_client_local_currencies {
    my ($client) = @_;

    my $precisions = Format::Util::Numbers->get_precision_config;
    my %local_currencies =
        map { ($_ => {fractional_digits => $precisions->{amount}{$_} // 2}) }
        grep { defined $_ } ($client->local_currency);

    return \%local_currencies;
}

=head2 logout
handles the user logout
=cut   

rpc logout => annotate_db_calls(
    read  => ['authdb', 'clientdb'],
    write => ['userdb']
) => sub {
    my $params = shift;

    if (my $email = $params->{email}) {
        my $token_details = $params->{token_details};
        my $loginid       = ($token_details and exists $token_details->{loginid}) ? @{$token_details}{qw/loginid/} : ();

        # if the $loginid is not undef, then only check for ip_mismatch.
        # PS: changing password will trigger logout, however, in that process, $loginid is not sent in, causing error in this line
        if ($loginid) {
            my $client = BOM::User::Client->new({
                loginid      => $loginid,
                db_operation => 'replica'
            });

            BOM::RPC::v3::Utility::check_ip_country(
                client_residence => $client->{residence},
                client_ip        => $params->{client_ip},
                country_code     => $params->{country_code},
                client_login_id  => $loginid,
                broker_code      => $client->{broker_code}) if $client->landing_company->ip_check_required;
        }

        if (my $user = BOM::User->new(email => $email)) {

            if ($params->{token_type} eq 'oauth_token') {
                # revoke tokens for user per app_id
                my $oauth  = BOM::Database::Model::OAuth->new;
                my $app_id = $oauth->get_app_id_by_token($params->{token});

                # Access token already has been removed from database. User is logged out.
                return {status => 1} unless $app_id;

                foreach my $c1 ($user->clients) {
                    $oauth->revoke_tokens_by_loginid_app($c1->loginid, $app_id);
                }

                # revoke all refresh tokens per user_id and app.
                $oauth->revoke_refresh_tokens_by_user_app_id($user->{id}, $app_id);
                $user->add_login_history(
                    environment => request()->login_env($params),
                    successful  => 't',
                    action      => 'logout',
                    app_id      => $app_id,
                    token       => $params->{token});

                BOM::User::AuditLog::log("user logout", join(',', $email, $loginid // ''));
            }
        }
    }
    return {status => 1};
};

rpc(
    "account_security",
    auth => ['trading', 'wallet'],
    sub {
        my $params        = shift;
        my $token_details = $params->{token_details};
        my $loginid       = $token_details->{loginid};
        my $totp_action   = $params->{args}->{totp_action};

        my $client = BOM::User::Client->new({loginid => $loginid});
        my $user   = BOM::User->new(email => $client->email);

        my $status = $user->{is_totp_enabled} // 0;

        # Get the Status of TOTP Activation
        if ($totp_action eq 'status') {
            return {totp => {is_enabled => $status}};
        }
        # Generate a new Secret Key if not already enabled
        elsif ($totp_action eq 'generate') {
            # return error if already enabled
            return _create_error('InvalidRequest', BOM::Platform::Context::localize('TOTP based 2FA is already enabled.')) if $status;
            # generate new secret key if it doesn't exits
            $user->update_totp_fields(secret_key => BOM::User::TOTP->generate_key)
                unless $user->{is_totp_enabled};
            # convert the key into base32 before sending
            return {totp => {secret_key => encode_base32($user->{secret_key})}};
        }
        # Enable or Disable 2FA
        elsif ($totp_action eq 'enable' || $totp_action eq 'disable') {
            # return error if user wants to enable 2fa and it's already enabled
            return _create_error('InvalidRequest', BOM::Platform::Context::localize('TOTP based 2FA is already enabled.'))
                if ($status == 1 && $totp_action eq 'enable');
            # return error if user wants to disable 2fa and it's already disabled
            return _create_error('InvalidRequest', BOM::Platform::Context::localize('TOTP based 2FA is already disabled.'))
                if ($status == 0 && $totp_action eq 'disable');

            # verify the provided OTP with secret key from user
            my $otp    = $params->{args}->{otp};
            my $verify = BOM::User::TOTP->verify_totp($user->{secret_key}, $otp);
            return _create_error('InvalidOTP', BOM::Platform::Context::localize('OTP verification failed')) unless ($otp and $verify);

            my $ua_fingerprint = $params->{token_details}->{ua_fingerprint};
            if ($totp_action eq 'enable') {
                # enable 2FA
                $user->update_totp_fields(
                    is_totp_enabled => 1,
                    ua_fingerprint  => $ua_fingerprint
                );
            } elsif ($totp_action eq 'disable') {
                # disable 2FA and reset secret key. Next time a new secret key should be generated
                $user->update_totp_fields(
                    is_totp_enabled => 0,
                    secret_key      => '',
                    ua_fingerprint  => $ua_fingerprint
                );
            }

            return {totp => {is_enabled => $user->{is_totp_enabled}}};
        }
    });

sub _create_error {
    my ($code, $message) = @_;
    return BOM::RPC::v3::Utility::create_error({
        code              => $code,
        message_to_client => $message
    });
}

=head2 valid_shared_token

Validating sharing OAuth token between third party apps

=over 4

=item * C<$oauth> - Instance of C<BOM::Database::Model::OAuth>.

=item * C<$app_id> - The app_id of the App requesting authorization.

=item * C<$token_extracted_app_id> - The app_id the token was created for.

=back

Returns 0 if not authorized, 1 in case of successful validation.

=cut

sub valid_shared_token {
    my ($oauth, $app_id, $token_extracted_app_id) = @_;

    return 1 unless BOM::Config::Runtime->instance->app_config->system->suspend->access_token_sharing;

    return 1 if $app_id == $token_extracted_app_id;

    return 0 unless $oauth->is_official_app($app_id);

    return 0 unless $oauth->is_official_app($token_extracted_app_id);

    return 1;
}

1;

package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use Date::Utility;
use List::Util qw(uniq any);
use Convert::Base32;
use Format::Util::Numbers qw/formatnumber/;

use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Utility qw(log_exception);
use BOM::Platform::Context qw (localize request);
use BOM::User;
use BOM::User::AuditLog;
use BOM::User::Client;
use BOM::User::TOTP;

use LandingCompany::Registry;

sub _get_upgradeable_landing_companies {
    my ($client) = @_;

    return [] unless $client->account_type eq 'trading';

    # List to store upgradeable companies
    my @upgradeable_landing_companies;

    my $countries_instance = request()->brand->countries_instance;

    # Get the gaming and financial company from the client's residence
    my $gaming_company    = $countries_instance->gaming_company_for_country($client->residence)    // '';
    my $financial_company = $countries_instance->financial_company_for_country($client->residence) // '';

    for my $lc (uniq($gaming_company, $financial_company)) {
        next unless $lc;

        my $rule_engine = BOM::Rules::Engine->new(
            client          => $client,
            landing_company => $lc,
            stop_on_failure => 0
        );
        # check accounts limit
        next if $rule_engine->apply_rules([qw/landing_company.accounts_limit_not_reached/])->has_failure;

        # check currency availability
        for my $currency (keys LandingCompany::Registry->new->get($lc)->legal_allowed_currencies->%*) {
            unless (
                $rule_engine->apply_rules(
                    [qw/landing_company.currency_is_allowed currency.is_available_for_new_account currency.is_currency_suspended/],
                    {
                        currency     => $currency,
                        account_type => 'trading'
                    }
                )->has_failure
                )
            {
                push @upgradeable_landing_companies, $lc;
                last;
            }
        }
    }

    return \@upgradeable_landing_companies;
}

rpc authorize => sub {
    my $params = shift;
    my ($token, $token_details, $client_ip) = @{$params}{qw/token token_details client_ip/};

    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidToken',
            message_to_client => BOM::Platform::Context::localize("Token is not valid for current ip address.")}
    ) if (exists $token_details->{valid_for_ip} and $token_details->{valid_for_ip} ne $client_ip);

    my ($loginid, $scopes) = @{$token_details}{qw/loginid scopes/};

    my $client = BOM::User::Client->get_client_instance($loginid, 'replica');
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client;

    my $user = $client->user;

    $user->setnx_preferred_language($params->{language}) if $params->{language} && $params->{language} =~ /^[A-Z]{2}$|^[A-Z]{2}_[A-Z]{2}$/i;

    $params->{app_id} = $params->{source};
    my $app_id = $params->{app_id};

    my ($lc, $brand_name) = ($client->landing_company, request()->brand->name);
    # check for not allowing cross brand tokens
    return BOM::RPC::v3::Utility::invalid_token_error() unless (grep { $brand_name eq $_ } @{$lc->allowed_for_brands});

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AccountDisabled',
            message_to_client => BOM::Platform::Context::localize("Account is disabled.")}) unless $client->is_available;

    my $token_type;

    if (length $token == 15) {

        $token_type = 'api_token';
        # add to login history for api token only as oauth login already creates an entry
        if ($params->{args}->{add_to_login_history} && $user) {
            $user->add_login_history(
                environment => request()->login_env($params),
                successful  => 't',
                action      => 'login',
                app_id      => $app_id
            );
        }

    } elsif (length $token == 32 && $token =~ /^a1-/) {
        $token_type = 'oauth_token';

        my $oauth = BOM::Database::Model::OAuth->new;
        $app_id = $oauth->get_app_id_by_token($params->{token}) // '';

        # App ID 4 comes from Backoffice, when client account is impersonated
        if ($app_id eq '4') {
            $user->add_login_history(
                environment => request()->login_env($params),
                successful  => 't',
                action      => 'login',
                app_id      => $app_id,
                token       => $params->{token});
        } else {
            BOM::RPC::v3::Utility::check_ip_country(
                client_residence => $client->{residence},
                client_ip        => $params->{client_ip},
                country_code     => $params->{country_code},
                client_login_id  => $params->{token_details}->{loginid},
                broker_code      => $client->{broker_code}) if $client->landing_company->ip_check_required;
        }
    }

    my $all_clients = $user->get_clients_in_sorted_order;

    # Return a client if:
    # its a virtual account
    # or selected account currency
    # or not disabled
    # is a regulated (EU) disabled account (disabled or enabled)
    my @client_list = grep { $_->is_virtual || $_->account || !$_->status->disabled || $_->landing_company->is_eu } @$all_clients;

    my @account_list = map { BOM::User::Client::get_account_details($_) } @client_list;

    my $precisions = Format::Util::Numbers->get_precision_config;
    my %local_currencies =
        map { ($_ => {fractional_digits => $precisions->{amount}{$_} // 2}) }
        grep { defined $_ } ($client->local_currency);

    my $account = $client->default_account;
    return {
        fullname                      => $client->full_name,
        user_id                       => $client->binary_user_id,
        loginid                       => $client->loginid,
        balance                       => $account ? formatnumber('amount', $account->currency_code(), $account->balance) : '0.00',
        currency                      => ($account ? $account->currency_code() : ''),
        local_currencies              => \%local_currencies,
        email                         => $client->email,
        country                       => $client->residence,
        landing_company_name          => $lc->short,
        landing_company_fullname      => $lc->name,
        preferred_language            => $user->preferred_language,
        scopes                        => $scopes,
        is_virtual                    => $client->is_virtual ? 1 : 0,
        upgradeable_landing_companies => _get_upgradeable_landing_companies($client),
        account_list                  => \@account_list,
        stash                         => {
            loginid              => $client->loginid,
            email                => $client->email,
            token                => $token,
            token_type           => $token_type,
            scopes               => $scopes,
            account_id           => ($account ? $account->id : ''),
            country              => $client->residence,
            currency             => ($account ? $account->currency_code() : ''),
            landing_company_name => $lc->short,
            is_virtual           => ($client->is_virtual ? 1 : 0),
            broker               => $client->broker,
        },
        $client->linked_accounts->%*,
    };
};

rpc logout => sub {
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

                foreach my $c1 ($user->clients) {
                    $oauth->revoke_tokens_by_loginid_app($c1->loginid, $app_id);
                }

                # revoke all refresh tokens per user_id and app.
                $oauth->revoke_refresh_tokens_by_user_app_id($user->{id}, $app_id);

                $user->add_login_history(
                    environment => request()->login_env($params),
                    successful  => 't',
                    action      => 'logout',
                    app_id      => $app_id // $params->{source},
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
            # return error if user wants to disbale 2fa and it's already disabled
            return _create_error('InvalidRequest', BOM::Platform::Context::localize('TOTP based 2FA is already disabled.'))
                if ($status == 0 && $totp_action eq 'disable');

            # verify the provided OTP with secret key from user
            my $otp    = $params->{args}->{otp};
            my $verify = BOM::User::TOTP->verify_totp($user->{secret_key}, $otp);
            return _create_error('InvalidOTP', BOM::Platform::Context::localize('OTP verification failed')) unless ($otp and $verify);

            if ($totp_action eq 'enable') {
                # enable 2FA
                $user->update_totp_fields(is_totp_enabled => 1);
            } elsif ($totp_action eq 'disable') {
                # disable 2FA and reset secret key. Next time a new secret key should be generated
                $user->update_totp_fields(
                    is_totp_enabled => 0,
                    secret_key      => ''
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

1;

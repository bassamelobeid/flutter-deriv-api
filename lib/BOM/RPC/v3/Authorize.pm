package BOM::RPC::v3::Authorize;

use strict;
use warnings;

use Date::Utility;
use List::MoreUtils qw(any);
use Convert::Base32;
use Format::Util::Numbers qw/formatnumber/;

use Brands;

use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize request);
use BOM::User;
use BOM::User::AuditLog;
use BOM::User::Client;
use BOM::User::TOTP;

use LandingCompany::Registry;

sub _get_upgradeable_landing_companies {
    my ($client_list, $client) = @_;

    # List to store upgradeable companies
    my @upgradeable_landing_companies;

    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;

    # Get the gaming and financial company from the client's residence
    my $gaming_company    = $countries_instance->gaming_company_for_country($client->residence);
    my $financial_company = $countries_instance->financial_company_for_country($client->residence);

    # Check if client has a gaming account or financial account
    # Otherwise, add them to the list
    # NOTE: Gaming has higher priority over financial
    if (   $gaming_company
        && $client->is_virtual
        && !(any { $_->landing_company->short eq $gaming_company } @$client_list))
    {
        push @upgradeable_landing_companies, $gaming_company;
    }

    # Some countries have financial but not gaming account
    if (  !$gaming_company
        && $financial_company
        && $client->is_virtual
        && !(any { $_->landing_company->short eq $financial_company } @$client_list))
    {
        push @upgradeable_landing_companies, $financial_company;
    }

    # In some cases, client has VRTC, MX/MLT, MF account
    # MX/MLT account might get duplicated, so MF should not have any companies
    if (@upgradeable_landing_companies && !$client->is_virtual) {
        @upgradeable_landing_companies = ();
    }

    # Some countries have both financial and gaming. Financial is added:
    # - if the list is empty
    # - two companies are not same
    # - current client is not virtual
    if (   !@upgradeable_landing_companies
        && ($gaming_company && $financial_company && $gaming_company ne $financial_company)
        && !$client->is_virtual
        && !(any { $_->landing_company->short eq $financial_company } @$client_list))
    {
        push @upgradeable_landing_companies, $financial_company;
    }

    # Multiple CR account scenario:
    # - client's landing company is CR
    # - client can upgrade to other CR accounts, assuming no fiat currency OR other cryptocurrencies
    if ($client->landing_company->short eq 'svg') {

        # Get siblings of the current client
        my $siblings = $client->real_account_siblings_information;

        # Push to upgradeable_landing_companies, if possible to open another CR account
        push @upgradeable_landing_companies, 'svg'
            if BOM::RPC::v3::Utility::get_available_currencies($siblings, $client->landing_company->short);
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

    my $client = BOM::User::Client->new({
        loginid      => $loginid,
        db_operation => 'replica'
    });
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client;

    my ($lc, $brand_name) = ($client->landing_company, request()->brand);
    # check for not allowing cross brand tokens
    return BOM::RPC::v3::Utility::invalid_token_error() unless (grep { $brand_name eq $_ } @{$lc->allowed_for_brands});

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AccountDisabled',
            message_to_client => BOM::Platform::Context::localize("Account is disabled.")}) unless $client->is_available;

    my $user = $client->user;
    my $token_type;
    if (length $token == 15) {
        $token_type = 'api_token';
        # add to login history for api token only as oauth login already creates an entry
        if ($params->{args}->{add_to_login_history} && $user) {
            $user->add_login_history(
                environment => BOM::RPC::v3::Utility::login_env($params),
                successful  => 't',
                action      => 'login',
            );
        }
    } elsif (length $token == 32 && $token =~ /^a1-/) {
        $token_type = 'oauth_token';
        BOM::RPC::v3::Utility::check_ip_country(
            client_residence => $client->{residence},
            client_ip        => $params->{client_ip},
            country_code     => $params->{country_code},
            client_login_id  => $params->{token_details}->{loginid},
            broker_code      => $client->{broker_code}) if $client->landing_company->ip_check_required;
    }

    my $_get_account_details = sub {
        my ($clnt, $curr) = @_;

        my $exclude_until = $clnt->get_self_exclusion_until_date;

        return {
            loginid              => $clnt->loginid,
            currency             => $curr,
            landing_company_name => $clnt->landing_company->short,
            is_disabled          => $clnt->status->disabled ? 1 : 0,
            is_virtual           => $clnt->is_virtual ? 1 : 0,
            $exclude_until ? (excluded_until => Date::Utility->new($exclude_until)->epoch) : ()};
    };

    my $client_list = $user->get_clients_in_sorted_order;

    my @account_list;
    my $currency;
    foreach my $clnt (@$client_list) {
        $currency = $clnt->default_account ? $clnt->default_account->currency_code() : '';
        push @account_list, $_get_account_details->($clnt, $currency);
    }

    my $account = $client->default_account;
    return {
        fullname => $client->full_name,
        user_id  => $client->binary_user_id,
        loginid  => $client->loginid,
        balance  => $account ? formatnumber('amount', $account->currency_code(), $account->balance) : '0.00',
        currency => ($account ? $account->currency_code() : ''),
        email    => $client->email,
        country  => $client->residence,
        landing_company_name     => $lc->short,
        landing_company_fullname => $lc->name,
        scopes                   => $scopes,
        is_virtual               => $client->is_virtual ? 1 : 0,
        upgradeable_landing_companies => _get_upgradeable_landing_companies($client_list, $client),
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
        },
    };
};

rpc logout => sub {
    my $params = shift;

    if (my $email = $params->{email}) {
        my $token_details = $params->{token_details};
        my ($loginid, $scopes) = ($token_details and exists $token_details->{loginid}) ? @{$token_details}{qw/loginid scopes/} : ();

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
                client_login_id  => $params->{token_details}->{loginid},
                broker_code      => $client->{broker_code}) if $client->landing_company->ip_check_required;
        }

        if (my $user = BOM::User->new(email => $email)) {
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
                    $user->add_login_history(
                        environment => BOM::RPC::v3::Utility::login_env($params),
                        successful  => 't',
                        action      => 'logout',
                    );
                    BOM::User::AuditLog::log("user logout", join(',', $email, $loginid // ''));
                }
            }
        }
    }
    return {status => 1};
};

rpc account_security => sub {
    my $params        = shift;
    my $token_details = $params->{token_details};
    my $loginid       = $token_details->{loginid};
    my $totp_action   = $params->{args}->{totp_action};

    my $client = BOM::User::Client->new({loginid => $loginid});
    my $user = BOM::User->new(email => $client->email);

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
        unless ($user->{secret_key}) {
            $user->update_totp_fields(secret_key => BOM::User::TOTP->generate_key);
        }
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
        my $otp = $params->{args}->{otp};
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
};

sub _create_error {
    my ($code, $message) = @_;
    return BOM::RPC::v3::Utility::create_error({
        code              => $code,
        message_to_client => $message
    });
}

1;

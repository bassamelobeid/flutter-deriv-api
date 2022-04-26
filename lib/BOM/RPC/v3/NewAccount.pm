package BOM::RPC::v3::NewAccount;

use strict;
use warnings;

use Syntax::Keyword::Try;
use List::MoreUtils qw(any);
use List::Util qw(minstr);
use Format::Util::Numbers qw/formatnumber/;
use Email::Valid;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';
use Log::Any qw($log);
use WebService::MyAffiliates;
use URI;

use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::Config;
use BOM::Database::Model::OAuth;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Locale;
use BOM::Platform::Redis;
use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::EmailVerification qw(email_verification);
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Cashier;
use BOM::User::Client::PaymentNotificationQueue;
use BOM::User::Client;
use BOM::User::FinancialAssessment qw(update_financial_assessment decode_fa);
use BOM::User;
use BOM::Rules::Engine;
use LandingCompany::Wallet;
use BOM::RPC::v3::MT5::Account;

use constant {
    TOKEN_GENERATION_ATTEMPTS => 5,
    REFRESH_TOKEN_LENGTH      => 29,
    REFRESH_TOKEN_TIMEOUT     => 60 * 60 * 24 * 60,    # 60 days.
    REQUEST_EMAIL_TOKEN_TTL   => 3600
};

requires_auth('trading', 'wallet');

sub _create_oauth_token {
    my ($app_id, $loginid) = @_;
    my ($access_token) = BOM::Database::Model::OAuth->new->store_access_token_only($app_id, $loginid);
    return $access_token;
}

sub request_email {
    my ($email, $args) = @_;

    send_email({
        to                    => $email,
        subject               => $args->{subject},
        template_name         => $args->{template_name},
        template_args         => $args->{template_args},
        use_email_template    => 1,
        email_content_is_html => 1,
        use_event             => 1,
    });

    return 1;
}

sub get_verification_uri {
    my $app_id = shift or return undef;
    return BOM::Database::Model::OAuth->new->get_verification_uri_by_app_id($app_id);
}

sub get_app_name {
    my $app_id = shift;
    return BOM::Database::Model::OAuth->new->get_names_by_app_id($app_id)->{$app_id};
}

rpc "verify_email",
    auth => [],    # unauthenticated
    sub {
    my $params = shift;
    my ($token_details, $website_name, $source, $language, $args) = @{$params}{qw/token_details website_name source language args/};

    my ($email, $type, $url_params) = @{$args}{qw/verify_email type url_parameters/};

    my $utm_medium   = $args->{url_parameters}->{utm_medium}   // '';
    my $utm_campaign = $args->{url_parameters}->{utm_campaign} // '';

    $email = lc $email;

    return BOM::RPC::v3::Utility::invalid_email() unless Email::Valid->address($email);

    my $error = BOM::RPC::v3::Utility::invalid_params($args);
    return $error if $error;

    my $code = BOM::Platform::Token->new({
            email       => $email,
            expires_in  => REQUEST_EMAIL_TOKEN_TTL,
            created_for => $type,
        })->token;

    my $verification = email_verification({
        code             => $code,
        website_name     => $website_name,
        verification_uri => get_verification_uri($source),
        language         => $language,
        source           => $source,
        app_name         => get_app_name($source),
        email            => $email,
        type             => $type,
        $url_params ? ($url_params->%*) : (),
    });

    my $existing_user = BOM::User->new(
        email => $email,
    );

    if ($existing_user and $existing_user->is_closed) {
        request_email($email, $verification->{closed_account}->());
        return {status => 1};
    }

    my $loginid = $token_details ? $token_details->{loginid} : undef;

    my $client;
    # If user is logged in, email for verification must belong to the logged in account
    if ($loginid) {
        $client = BOM::User::Client->new({
            loginid      => $loginid,
            db_operation => 'replica'
        });
        return {status => 1} unless $client->email eq $email;
    }

    if ($existing_user and $type eq 'reset_password') {
        my $data = $verification->{reset_password}->();
        BOM::Platform::Event::Emitter::emit(
            'reset_password_request',
            {
                loginid    => $existing_user->get_default_client->loginid,
                properties => {
                    verification_url => $data->{template_args}->{verification_url}  // '',
                    social_login     => $data->{template_args}->{has_social_signup} // '',
                    first_name       => $existing_user->get_default_client->first_name,
                    code             => $data->{template_args}->{code} // '',
                    email            => $email,
                },
            });
    } elsif ($existing_user and $type eq 'request_email') {

        my $data              = $verification->{request_email}->();
        my $has_social_signup = $data->{template_args}->{has_social_signup} ? 1 : 0;
        my $uri               = $data->{template_args}->{verification_url} // '';

        BOM::Platform::Event::Emitter::emit(
            'request_change_email',
            {
                loginid    => $existing_user->get_default_client->loginid,
                properties => {
                    verification_uri      => $data->{template_args}->{verification_url} // '',
                    first_name            => $existing_user->get_default_client->first_name,
                    code                  => $data->{template_args}->{code} // '',
                    email                 => $email,
                    time_to_expire_in_min => REQUEST_EMAIL_TOKEN_TTL / 60,
                    language              => $language,
                    social_signup         => $has_social_signup,
                    live_chat_url         => request()->brand->live_chat_url
                },
            });
    } elsif ($type eq 'account_opening') {
        if ($utm_medium eq 'affiliate' and $utm_campaign eq 'MyAffiliates' and $url_params->{affiliate_token}) {
            my $config = BOM::Config::third_party()->{myaffiliates};
            my $aff    = WebService::MyAffiliates->new(
                user    => $config->{user},
                pass    => $config->{pass},
                host    => $config->{host},
                timeout => 10
            );

            my $myaffiliate_email    = '';
            my $received_aff_details = $aff->get_affiliate_details($url_params->{affiliate_token});
            if ($received_aff_details and $received_aff_details->{TOKEN}->{USER_ID} !~ m/Error/) {
                $myaffiliate_email = $received_aff_details->{TOKEN}->{USER}->{EMAIL} // '';
            } else {
                $log->warnf("Could not fetch affiliate details from MyAffiliates. Please check credentials: %s", $aff->errstr);
            }
            if ($myaffiliate_email eq $email) {
                request_email($email, $verification->{account_opening_existing}->());
            } else {
                my $data = $verification->{account_opening_new}->();
                BOM::Platform::Event::Emitter::emit(
                    'account_opening_new',
                    {
                        verification_url => $data->{template_args}->{verification_url} // '',
                        code             => $data->{template_args}->{code}             // '',
                        email            => $email,
                        live_chat_url    => $data->{template_args}->{live_chat_url} // '',
                    });
            }
        } else {
            unless ($existing_user) {
                my $data = $verification->{account_opening_new}->();
                BOM::Platform::Event::Emitter::emit(
                    'account_opening_new',
                    {
                        verification_url => $data->{template_args}->{verification_url} // '',
                        code             => $data->{template_args}->{code}             // '',
                        email            => $email,
                        live_chat_url    => $data->{template_args}->{live_chat_url} // '',
                    });
            } else {
                request_email($email, $verification->{account_opening_existing}->());
            }
        }

    } elsif ($client and ($type eq 'paymentagent_withdraw' or $type eq 'payment_withdraw')) {
        my $validation_error = BOM::RPC::v3::Utility::cashier_validation($client, $type);
        return $validation_error if $validation_error;

        $validation_error = BOM::RPC::v3::Cashier::payment_agent_withdrawal_automation($client);
        return $validation_error if $validation_error;

        if (_is_impersonating_client($params->{token})) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'Permission Denied',
                    message_to_client => localize('You can not perform a withdrawal while impersonating an account')});
        }
        request_email($email, $verification->{payment_withdraw}->());
    } elsif ($existing_user and $type eq 'trading_platform_password_reset') {
        my $verification = $verification->{trading_platform_password_reset}->();
        request_email($email, $verification);

        BOM::Platform::Event::Emitter::emit(
            'trading_platform_password_reset_request',
            {
                loginid    => $existing_user->get_default_client->loginid,
                properties => {
                    first_name        => $existing_user->get_default_client->first_name,
                    verification_url  => $verification->{template_args}{verification_url},
                    code              => $verification->{template_args}{code},
                    dxtrade_available => $verification->{template_args}{dxtrade_available},
                },
            });
    } elsif ($existing_user and $type eq 'trading_platform_mt5_password_reset') {
        my $verification = $verification->{trading_platform_mt5_password_reset}->();
        request_email($email, $verification);

        BOM::Platform::Event::Emitter::emit(
            'trading_platform_password_reset_request',
            {
                loginid    => $existing_user->get_default_client->loginid,
                properties => {
                    first_name       => $existing_user->get_default_client->first_name,
                    verification_url => $verification->{template_args}{verification_url},
                    code             => $verification->{template_args}{code},
                    platform         => 'mt5',
                },
            });
    } elsif ($existing_user and $type eq 'trading_platform_dxtrade_password_reset') {
        my $verification = $verification->{trading_platform_dxtrade_password_reset}->();
        request_email($email, $verification);

        BOM::Platform::Event::Emitter::emit(
            'trading_platform_password_reset_request',
            {
                loginid    => $existing_user->get_default_client->loginid,
                properties => {
                    first_name       => $existing_user->get_default_client->first_name,
                    verification_url => $verification->{template_args}{verification_url},
                    code             => $verification->{template_args}{code},
                    platform         => 'dxtrade',
                },
            });
    } elsif ($existing_user and $type eq 'trading_platform_investor_password_reset') {
        my $verification = $verification->{trading_platform_investor_password_reset}->();
        request_email($email, $verification);

        BOM::Platform::Event::Emitter::emit(
            'trading_platform_investor_password_reset_request',
            {
                loginid    => $existing_user->get_default_client->loginid,
                properties => {
                    first_name       => $existing_user->get_default_client->first_name,
                    verification_url => $verification->{template_args}{verification_url},
                    code             => $verification->{template_args}{code},
                },
            });
    }

    # always return 1, so not to leak client's email
    return {status => 1};
    };

=head2 _is_impersonating_client

Description: Checks if this is an internal app like backend - if so
we are impersonating an account.
Takes the following arguments as named parameters

=over 4

=item - $token:  The token id used to authenticate with


=back

Returns a boolean

=cut

sub _is_impersonating_client {
    my ($token) = @_;

    my $oauth_db = BOM::Database::Model::OAuth->new;
    my $app_id   = $oauth_db->get_app_id_by_token($token);
    return $oauth_db->is_internal($app_id);
}

sub _update_professional_existing_clients {

    my ($clients, $professional_status, $professional_requested) = @_;

    if ($professional_requested && $clients) {
        foreach my $client (@{$clients}) {
            my $error = BOM::RPC::v3::Utility::set_professional_status($client, $professional_status, $professional_requested);
            return $error if $error;
        }
    }

    return undef;
}

sub _get_professional_details_clients {
    my ($user, $args) = @_;

    # Filter out MF/CR clients
    my @clients = map { $user->clients_for_landing_company($_) } qw/svg maltainvest/;

    # Get the professional flags
    my $professional_status = any { $_->status->professional } @clients;
    my $professional_requested =
        !$professional_status && (($args->{client_type} eq 'professional') || any { $_->status->professional_requested } @clients);

    return (\@clients, $professional_status, $professional_requested);
}

rpc new_account_real => sub {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};

    $client->residence($args->{residence}) unless $client->residence;
    my $countries_instance = request()->brand->countries_instance;

    my $market_type = 'synthetic';
    my $company     = $countries_instance->gaming_company_for_country($client->residence);
    unless ($company) {
        # for CR countries like Australia (au) where only financial market is available.
        $market_type = 'financial';
        $company     = $countries_instance->financial_company_for_country($client->residence) // '';

        return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccountRegion') unless $company;
    }

    my $broker = LandingCompany::Registry->by_name($company)->broker_codes->[0];

    # Send error if a maltainvest account  is going to be created here;
    # because they should be creaed using new_account_maltainvest call
    return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccount')
        unless ($company // '' and $company ne 'maltainvest');

    my $response = create_new_real_account(
        client          => $client,
        args            => $args,
        account_type    => 'trading',
        broker_code     => $broker,
        market_type     => $market_type,
        environment     => request()->login_env($params),
        ip              => $params->{client_ip} // '',
        source          => $params->{source},
        landing_company => $company,
    );
    return $response if $response->{error};

    my $new_client = $response->{client};

    return {
        client_id                 => $new_client->loginid,
        landing_company           => $new_client->landing_company->name,
        landing_company_shortcode => $new_client->landing_company->short,
        oauth_token               => $response->{oauth_token},
        $args->{currency} ? (currency => $new_client->currency) : (),
    };
};

rpc new_account_maltainvest => sub {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};
    my $user = $client->user;

    $client->residence($args->{residence}) unless $client->residence;
    my $countries_instance = request()->brand->countries_instance;

    my $company = $countries_instance->financial_company_for_country($client->residence) // '';

    return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccount') unless $company;

    # this call is exclusively for maltainvest
    return BOM::RPC::v3::Utility::permission_error if ($company ne 'maltainvest');

    my $broker = LandingCompany::Registry->by_name($company)->broker_codes->[0];

    my $response = create_new_real_account(
        client          => $client,
        args            => $args,
        account_type    => 'trading',
        broker_code     => $broker,
        market_type     => 'financial',
        environment     => request()->login_env($params),
        ip              => $params->{client_ip} // '',
        source          => $params->{source},
        landing_company => 'maltainvest',
    );
    return $response if $response->{error};

    my $new_client = $response->{client};

    # Client's citizenship can only be set from backoffice.
    # However, when a Deriv Investments (Europe) Limited account is created, the citizenship
    # is not updated in the new account.
    # Hence, the following check is necessary
    $new_client->citizen($client->citizen) if ($client->citizen && !$client->is_virtual);
    # Save new account
    if (not $new_client->save) {
        stats_inc('bom_rpc.v_3.call_failure.count', {tags => ["rpc:new_account_maltainvest"]});
        return BOM::RPC::v3::Utility::client_error();

    }

    # In case of having more than a tax residence, client residence will replaced.
    my $selected_tax_residence = $args->{tax_residence} =~ /\,/g ? $args->{residence} : $args->{tax_residence};
    my $tin_format             = $countries_instance->get_tin_format($selected_tax_residence);
    my $client_tin             = $countries_instance->clean_tin_format($args->{tax_identification_number}, $selected_tax_residence);
    if ($tin_format) {
        stats_inc('bom_rpc.v_3.new_account_maltainvest.called_with_wrong_TIN_format.count')
            unless (any { $client_tin =~ m/$_/ } @$tin_format);
    }

    return {
        client_id                 => $new_client->loginid,
        landing_company           => $new_client->landing_company->name,
        landing_company_shortcode => $new_client->landing_company->short,
        oauth_token               => $response->{oauth_token},
    };
};

rpc "new_account_virtual",
    auth => [],
    sub {
    my $params = shift;
    my $args   = $params->{args};

    $args->{token_details} = delete $params->{token_details};
    $args->{type} //= 'trading';    # default to 'trading'

    if ($args->{type} eq 'wallet' && BOM::Config::Runtime->instance->app_config->system->suspend->wallets) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'PermissionDenied',
            message_to_client => localize("Wallet account creation is currently suspended."),
        });
    }

    if ($args->{token_details} and not $args->{verification_code}) {
        my $scopes = $args->{token_details}->{scopes};
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => localize("The token is invalid, requires 'admin' scope.")}) unless (any { $_ eq 'admin' } @$scopes);
    }

    my ($client, $account);
    try {
        $args->{ip}          = $params->{client_ip} // '';
        $args->{country}     = uc($params->{country_code} // '');
        $args->{environment} = request()->login_env($params);
        $args->{source}      = $params->{source};

        # Pre-set email if client is authorized
        if ($args->{token_details}) {
            my $user = BOM::User->new(loginid => $args->{token_details}->{loginid});
            $args->{email} = $user->{email};
        }

        $client  = create_virtual_account($args);
        $account = $client->default_account;

        my $oauth_model = BOM::Database::Model::OAuth->new;
        my $refresh_token;

        # this is the first account of the user
        if (scalar $client->user->clients == 1) {
            $refresh_token = $oauth_model->generate_refresh_token($client->binary_user_id, $params->{source});
        }

        return {
            client_id   => $client->loginid,
            email       => $client->email,
            currency    => $account->currency_code(),
            balance     => formatnumber('amount', $account->currency_code(), $account->balance),
            oauth_token => _create_oauth_token($params->{source}, $client->loginid),
            type        => $args->{type},
            $refresh_token ? (refresh_token => $refresh_token) : (),
        };
    } catch ($e) {
        my $error_map = BOM::RPC::v3::Utility::error_map();
        my $error->{code} = $e;
        $error = $e->{error} // $e if (ref $e eq 'HASH');
        $error->{message_to_client} = $error->{message_to_client} // $error_map->{$error->{code}};

        return BOM::RPC::v3::Utility::client_error() unless ($error->{message_to_client});

        return BOM::RPC::v3::Utility::create_error({
                code              => $error->{code},
                message_to_client => $error->{message_to_client},
                details           => $error->{details}});
    };
    };

rpc new_account_wallet => sub {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};

    if (BOM::Config::Runtime->instance->app_config->system->suspend->wallets) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'PermissionDenied',
            message_to_client => localize("Wallet account creation is currently suspended."),
        });
    }

    $args->{residence} //= $client->residence;
    $client->residence($args->{residence}) unless $client->residence;
    my $countries_instance = request()->brand->countries_instance;

    my $wallet_short_code = $countries_instance->wallet_company_for_country($client->residence, 'real');
    my $wallet_lc         = LandingCompany::Wallet::get($wallet_short_code // '');

    return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccountRegion') unless $wallet_lc;

    my $company = $wallet_lc->{landing_company};
    my $broker  = $wallet_lc->{broker_codes}->[0];

    my $response = create_new_real_account(
        client          => $client,
        args            => $args,
        account_type    => 'wallet',
        broker_code     => $broker,
        landing_company => $company,
        environment     => request()->login_env($params),
        ip              => $params->{client_ip} // '',
        source          => $params->{source},
    );
    return $response if $response->{error};

    my $new_client      = $response->{client};
    my $landing_company = $new_client->landing_company;

    return {
        client_id                 => $new_client->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short,
        oauth_token               => _create_oauth_token($params->{source}, $new_client->loginid),
        currency                  => $new_client->currency,
    };
};

=head2 create_virtual_account

Create a new virtual wallet or trading account

=over 4

=item * C<args> new account details

=back

Returns a C<BOM::User::Client> or C<BOM::User::Wallet> instance

=cut

sub create_virtual_account {
    my ($args) = @_;

    # Non-PEP declaration is not made for virtual accounts
    delete $args->{non_pep_declaration};

    my ($error);

    if ($args->{token_details} and not $args->{verification_code}) {
        # To create a second virtual account, check for token; password is redundant
        for my $field (qw( client_password )) {
            die +{
                code              => 'InvalidRequestParams',
                message_to_client => localize('Invalid request parameters.'),
                details           => {field => $field}}
                if ($args->{$field});
        }
        my $user = BOM::User->new(loginid => $args->{token_details}->{loginid});
        $args->{email} = $user->{email};
        # get residence from an existing client
        $args->{residence} = $user->get_default_client->residence;
    } else {
        # To create a new user, check for client_password, residence and verification_code
        # These required fields were excluded from JSON schema, we need to handle it here
        for my $field (qw( client_password residence verification_code )) {
            die +{
                code    => 'InputValidationFailed',
                details => {field => $field}} unless ($args->{$field});
        }

        my $verification_code = $args->{verification_code};
        $args->{email} = BOM::Platform::Token->new({token => $verification_code})->email unless $args->{email};

        $error = BOM::RPC::v3::Utility::is_verification_token_valid($verification_code, $args->{email}, 'account_opening')->{error};
        die $error if $error;

        $error = BOM::RPC::v3::Utility::check_password({
                email        => $args->{email},
                new_password => $args->{client_password}});
        die $error if $error;
    }

    if ($args->{type} eq 'wallet') {
        my $countries_instance = request()->brand->countries_instance;
        my $company_name       = $countries_instance->wallet_company_for_country($args->{residence}, 'virtual');

        die BOM::RPC::v3::Utility::create_error_by_code('invalid residence')
            if ($company_name // 'none') eq 'none';
    }

    # Create account
    my $account_args = {
        ip      => $args->{id},
        country => $args->{country},
        details => {
            email           => $args->{email},
            email_consent   => $args->{email_consent},
            client_password => $args->{client_password},
            residence       => $args->{residence},
            source          => $args->{source},
        },
        utm_data => {},
        type     => $args->{type},
    };

    $account_args->{details}->{myaffiliates_token} = $args->{affiliate_token} if $args->{affiliate_token};

    my $regex_validation = {qr{^utm_.+} => qr{^[\w\s\.\-_]{1,100}$}};
    my @tags_list        = qw(date_first_contact gclid_url signup_device utm_campaign utm_medium utm_source);

    my $filtered_url_parameters = BOM::Platform::Utility::extract_valid_params(\@tags_list, $args, $regex_validation);
    foreach my $k (keys $filtered_url_parameters->%*) {
        $account_args->{details}->{$k} = $args->{$k} if $args->{$k};
    }

    @tags_list = qw(
        utm_ad_id        utm_adgroup_id utm_adrollclk_id utm_campaign_id utm_content utm_fbcl_id
        utm_gl_client_id utm_msclk_id   utm_term
    );

    $filtered_url_parameters = BOM::Platform::Utility::extract_valid_params(\@tags_list, $args, $regex_validation);
    foreach my $k (keys $filtered_url_parameters->%*) {
        $account_args->{utm_data}->{$k} = $args->{$k} if $args->{$k};
    }

    my $account = BOM::Platform::Account::Virtual::create_account($account_args);
    die $account->{error} if $account->{error};

    # Check if it is from UK, instantly mark it as unwelcome
    my $config = request()->brand->countries_instance->countries_list->{$account->{client}->residence};
    if ($config->{virtual_age_verification}) {
        $account->{client}->status->set('unwelcome', 'SYSTEM', 'Pending proof of age');
    }

    my $user = $account->{user};
    $user->add_login_history(
        action      => 'login',
        environment => $args->{environment},
        successful  => 't',
        app_id      => $args->{source});

    BOM::User::AuditLog::log("successful login", "$args->{email}");

    my $client = $account->{client};
    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'virtual',
        currency      => $client->currency,
        loginid       => $client->loginid,
        type          => 'newaccount',
        amount        => 0,
        payment_agent => 0,
    );

    my $utm_tags = {};
    @tags_list = qw(date_first_contact gclid_url signup_device utm_campaign utm_content utm_medium utm_source utm_term);
    foreach my $tag (@tags_list) {
        $utm_tags->{$tag} = $args->{$tag} if $args->{$tag};
    }

    BOM::Platform::Event::Emitter::emit(
        'signup',
        {
            loginid    => $client->loginid,
            properties => {
                type     => $args->{type} // 'trading',
                subtype  => 'virtual',
                utm_tags => BOM::Platform::Utility::extract_valid_params(\@tags_list, $utm_tags, $regex_validation)}});

    return $client;
}

=head2 create_new_real_account

Creates a new real account. It's called by all real account opening RPC handlers.

=over 4

=item * C<client> form client which the new real account is being created
=item * C<args> new account request arguments

=back

Returns a C<BOM::User::Client> instance

=cut

sub create_new_real_account {
    my %params = @_;
    my $client = $params{client};
    my $args   = $params{args};

    $args->{$_} = $params{$_} for (qw/broker_code account_type market_type source landing_company environment/);

    my $details_ref = _new_account_pre_process($args, $client);
    my $error_map   = BOM::RPC::v3::Utility::error_map();
    if ($details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $details_ref->{error},
                message_to_client => $details_ref->{message_to_client} // $error_map->{$details_ref->{error}},
                details           => $details_ref->{details}});
    }

    my $user = $client->user;
    my ($clients, $professional_status, $professional_requested) = _get_professional_details_clients($user, $args);
    my $val = _update_professional_existing_clients($clients, $professional_status, $professional_requested);
    return $val if $val;

    my $sibling_has_migrated_universal_password_status = any { $_->status->migrated_universal_password } $user->clients;
    if (!BOM::Config::Runtime->instance->app_config->system->suspend->universal_password && $sibling_has_migrated_universal_password_status) {
        $val = _update_migrated_universal_password_existing_clients($clients);
        return $val if $val;
    }

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    try {
        # Rules are applied on actual request arguments ($args),
        # not the initialized values ($details_ref->{details}) used for creating the client object.
        $rule_engine->verify_action(
            'new_account',
            %$args,
            loginid         => $client->loginid,
            landing_company => $params{landing_company},
        );
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    };

    my $lock = BOM::Platform::Redis::acquire_lock($client->user_id, 10);
    return BOM::RPC::v3::Utility::rate_limit_error() if not $lock;

    my $create_account_sub =
        $params{landing_company} eq 'maltainvest'
        ? \&BOM::Platform::Account::Real::maltainvest::create_account
        : \&BOM::Platform::Account::Real::default::create_account;

    # It's safe to create the new client now
    my $acc;
    try {
        $acc = $create_account_sub->({
            ip          => $params{ip} // '',
            country     => uc($client->residence // ''),
            from_client => $client,
            user        => $user,
            details     => $details_ref->{details},
            params      => $args,
        });
    } finally {
        BOM::Platform::Redis::release_lock($client->user_id);
    }

    my $error;
    if ($error = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $error,
                message_to_client => $error_map->{$error}});
    }

    my $new_client = $acc->{client};

    _new_account_post_process(
        client                                         => $client,
        new_client                                     => $new_client,
        args                                           => $args,
        professional_status                            => $professional_status,
        professional_requested                         => $professional_requested,
        sibling_has_migrated_universal_password_status => $sibling_has_migrated_universal_password_status
    );

    return {
        client      => $new_client,
        oauth_token => _create_oauth_token($params{source}, $new_client->loginid),
    };
}

=head2 _new_account_pre_process

Validates and initilizes account details on real account opening, taking following arguments:

=over 4

=item * C<args> - RPC call arguments

=item * C<client> - The client who is requesting for account opening

=item * C<broker> - broker code of the new account

=item * C<source> - the source app id

=back

Returns {
    error   => C<error_code>
    details => C<detail info>
}

=cut

sub _new_account_pre_process {
    my ($args, $client) = @_;

    $client = (sort { $b->date_joined cmp $a->date_joined } grep { not $_->is_virtual } $client->user->clients(include_disabled => 0))[0] // $client
        if $client->is_virtual;

    # has remianed from the history of design
    $args->{client_type} //= 'retail';

    my $broker       = $args->{broker_code};
    my $market_type  = $args->{market_type};
    my $account_type = $args->{account_type};

    if (BOM::Config::Runtime->instance->app_config->system->suspend->new_accounts) {
        my $loginid   = $client->loginid;
        my $residence = $client->residence;
        warn "acc opening err: from_loginid:$loginid, account_type:$account_type, residence:$residence, error: - new account opening suspended";
        return BOM::RPC::v3::Utility::create_error_by_code('InvalidAccount');
    }

    return BOM::RPC::v3::Utility::create_error_by_code('NoResidence') unless $client->residence;

    unless ($client->is_virtual) {
        # Lets populate all sensitive data from current client, ignoring provided input
        # this logic should gone after we separate new_account with new_currency for account
        foreach (qw/first_name last_name residence address_city phone date_of_birth address_line_1/) {
            $args->{$_} = $client->$_ if $client->$_;
        }
    }

    my $non_pep_declaration = delete $args->{non_pep_declaration};
    $args->{non_pep_declaration_time} = _get_non_pep_declaration_time($client, $args->{landing_company}, $non_pep_declaration, $args->{source});

    # If it's a virtual client, replace client with the newest real account if any
    if ($client->is_virtual) {
        $client = (sort { $b->date_joined cmp $a->date_joined } grep { not $_->is_virtual } $client->user->clients(include_disabled => 0))[0]
            // $client;
    }

    my $details = {
        broker_code                   => $broker,
        email                         => $client->email,
        client_password               => $client->password,
        myaffiliates_token_registered => 0,
        checked_affiliate_exposures   => 0,
        latest_environment            => '',
        source                        => $args->{source},
    };

    $details->{myaffiliates_token} = _compute_affiliate_token($client, $args);

    delete $args->{affiliate_token} if (exists $args->{affiliate_token});

    my @fields_to_duplicate =
        qw(citizen salutation first_name last_name date_of_birth residence address_line_1 address_line_2 address_city address_state address_postcode phone secret_question secret_answer place_of_birth tax_residence tax_identification_number account_opening_reason);

    unless ($client->is_virtual) {
        for my $field (@fields_to_duplicate) {
            if ($field eq "secret_answer") {
                $args->{$field} ||= BOM::User::Utility::decrypt_secret_answer($client->$field);
            } else {
                $args->{$field} ||= $client->$field;
            }
        }
    }

    my $error = $client->format_input_details($args);
    return $error if $error;

    $args->{secret_answer} = BOM::User::Utility::encrypt_secret_answer($args->{secret_answer}) if $args->{secret_answer};

    # This exist to accommodate some rules in our database (mostly NOT NULL and NULL constraints). Should change to be more consistent. Also used to filter the args to return for new account creation.
    my %default_values = (
        citizen                   => '',
        salutation                => '',
        first_name                => '',
        last_name                 => '',
        date_of_birth             => undef,
        residence                 => '',
        address_line_1            => '',
        address_line_2            => '',
        address_city              => '',
        address_state             => '',
        address_postcode          => '',
        phone                     => '',
        secret_question           => '',
        secret_answer             => '',
        place_of_birth            => '',
        tax_residence             => '',
        tax_identification_number => '',
        account_opening_reason    => '',
        place_of_birth            => undef,
        tax_residence             => undef,
        tax_identification_number => undef,
        non_pep_declaration_time  => undef,
        currency                  => undef,
        payment_method            => undef,
    );

    for my $field (keys %default_values) {
        $details->{$field} = $args->{$field} // $default_values{$field};
    }
    $details->{type} = $account_type;

    if ($account_type eq 'trading' and $market_type eq 'financial') {
        # When a Deriv (Europe) Limited/Deriv (MX) Ltd account is created,
        # the 'place of birth' field is not present.
        # After creating Deriv (Europe) Limited/Deriv (MX) Ltd account, client can select
        # their place of birth in their profile settings.
        # However, when a Deriv Investments (Europe) Limited account account is created,
        # the 'place of birth' field is mandatory.
        # Hence, this check is added for backward compatibility (assuming no place of birth is selected)
        if (!$client->place_of_birth && $args->{place_of_birth} && !$client->is_virtual) {
            $client->place_of_birth($args->{place_of_birth});

            if (not $client->save) {
                stats_inc('bom_rpc.v_3.call_failure.count', {tags => ["rpc:new_account_maltainvest"]});
                return BOM::RPC::v3::Utility::client_error();
            }
        }
    }

    return {details => $details};
}

=head2 _new_account_post_process

Validates and initilizes account details on real account opening, taking following arguments:

=over 4

=item * C<args> - RPC call arguments

=item * C<client> - The client who is requesting for account opening

=item * C<broker> - broker code of the new account

=item * C<source> - the source app id

=back

Returns {
    error   => C<error_code>
    details => C<detail info>
}

=cut

sub _new_account_post_process {
    my %par = @_;

    my ($client, $new_client, $args, $professional_status, $professional_requested, $sibling_has_migrated_universal_password_status) =
        @par{qw/client new_client args professional_status  professional_requested sibling_has_migrated_universal_password_status/};

    # Ported from previous implementations of new_account_real, new_account_maltainvest  and new_wallet_real RPC codes
    my $error;
    try {
        $new_client->sync_authentication_from_siblings;
    } catch {
        return BOM::RPC::v3::Utility::client_error()
    };
    # Set affiliate data if required
    if ($new_client->landing_company->is_for_affiliates) {
        $new_client->set_affiliate_info({affiliate_plan => $args->{affiliate_plan}});
    }

    if (any { $args->{account_type} eq $_ } qw/trading affiliate/) {

        update_financial_assessment($client->user, decode_fa($client->financial_assessment()))
            if $args->{market_type} eq 'synthetic' && $client->financial_assessment();

        # XXX If we fail after account creation then we could end up with these flags not set,
        # ideally should be handled in a single transaction
        # as account is already created so no need to die on status set
        # else it will give false impression to client
        $error = BOM::RPC::v3::Utility::set_professional_status($new_client, $professional_status, $professional_requested);
        return $error if $error;

        if ($args->{currency}) {
            my $currency_set_result = BOM::RPC::v3::Accounts::set_account_currency({
                    client   => $new_client,
                    currency => $args->{currency}});
            return $currency_set_result if $currency_set_result->{error};
        }

        my $config = request()->brand->countries_instance->countries_list->{$new_client->residence};
        if (   $config->{need_set_max_turnover_limit}
            or $new_client->landing_company->check_max_turnover_limit_is_set)
        {    # RTS 12 - Financial Limits - UK Clients and MLT Clients
            try { $new_client->status->set('max_turnover_limit_not_set', 'system', 'new GB client or MLT client - have to set turnover limit') }
            catch { return BOM::RPC::v3::Utility::client_error() }
        }
        try {
            $new_client->sync_authentication_from_siblings;
        } catch ($error) {
            $log->errorf('Failed to sync authentication for client %s: %s', $new_client->loginid, $error);
            return BOM::RPC::v3::Utility::client_error()
        };
    }

    if (!BOM::Config::Runtime->instance->app_config->system->suspend->universal_password && $sibling_has_migrated_universal_password_status) {
        $error = BOM::RPC::v3::Utility::set_migrated_universal_password_status($new_client);
        return $error if $error;
    }

    # Not sure if the following notfications are required for wallet creation or not
    $client->user->add_login_history(
        action      => 'login',
        environment => $args->{environment},
        successful  => 't',
        app_id      => $args->{source});

    BOM::User::AuditLog::log("successful login", "$client->email");
    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'real',
        currency      => $args->{currency} // 'USD',
        loginid       => $new_client->loginid,
        type          => 'newaccount',
        amount        => 0,
        payment_agent => 0,
    );

    BOM::Platform::Event::Emitter::emit(
        'signup',
        {
            loginid    => $new_client->loginid,
            properties => {
                # TODO: CHECK PROPERTIES AGAINST EVENT HANDLER
                type    => $args->{account_type},
                subtype => 'real'
            }});
}

=head2 _get_non_pep_declaration_time

Called on new real account rpc calls, it returns the time clients have submitted their (non-)PEP declartion for a landing company.
If there is an older account in the same landing company, it's declaration time will be returned.
If there is not any non-PEP declaration found for the specified landing company, current time will be returned.

#TODO(Mat): If all apps (both official and third-party) send non_pep_declaration whenever it's submitted by clients on signup,
#    the return value should be changed to undef if non-PEP declaration was missing.

=over 4

=item * C<client> - current client who has initated a new real account request

=item * C<company> - landing company of the new account being created

= item * C<non_pep_declaration> - boolean value that determines if non-PEP declaration is made through the current signup process

- item * C<app_id> - the id of the app through which the request is made

=back

returns the time when the client has declared they are not a PEP/RCA for the requested C<company>.

=cut

sub _get_non_pep_declaration_time {
    my ($client, $company, $non_pep_declaration) = @_;

    return time if $non_pep_declaration;

    # declaration time can be safely extracted from older siblings in the same landing company.
    my @same_lc_siblings = $client->user->clients_for_landing_company($company);

    for (@same_lc_siblings) {
        return $_->non_pep_declaration_time if $_->non_pep_declaration_time;
    }

    #TODO(Mat): we will return undef here, provided that nothing is logged by the above line
    #           (non_pep_declaration is sent from all appls for the first real account per landing complany).
    return minstr(map { $_->date_joined } @same_lc_siblings) || time;
}

=head2 affiliate_account_add

Creates a new affiliate client account.

Will do:

=over 4

=item - The Affiliate account (new broker code)

=item - Create an MT5 real gaming account

=item - Add a new account in Affiliate System

=back

Will return the following data:

=over 4

=item - C<client_id> the new client loginid

=item - C<landing_company>

=item - C<landing_company_shortcode>

=item - C<Affiliate User ID>

=back

=cut

rpc "affiliate_account_add", sub {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};

    $log->tracef("Invoked affiliate_account_add for:\n%s \n%s", $client, $args);

    my $broker       = 'AFF';
    my $company      = LandingCompany::Registry->by_broker($broker);
    my $company_name = $company->name;

    return BOM::RPC::v3::Utility::create_error({
        code              => 'PermissionDenied',
        message_to_client => "This API is a work in progress. $broker account will be created for landing company: $company_name."
    });
};

=head2 _compute_affiliate_token

=head3 Parameters:

=over 2

=item * C<client> - The client who is requesting for account opening

=item * C<args> - RPC call arguments

=back

=head3 Return:

=over 1

=item * C<affiliate_token> the affliate token

=back

=pod

B<Uses Cases:>

1. User creates first account with affiliate ==> add affiliate 

2. User creates second account with affiliate ==> do not add affliate token ( this user belongs to deriv)

3. User creates second account without affiliate token but other siblings already have token ==> use current token

=cut

sub _compute_affiliate_token {

    my ($client, $args) = @_;
    my $affiliate_token = $args->{affiliate_token} || '';
    my $user            = $client->user;
    my @clients         = $user->clients;
    if (@clients > 0) {
        @clients         = sort { $a->date_joined cmp $b->date_joined } @clients;
        $affiliate_token = $clients[0]->myaffiliates_token || $affiliate_token;
    }

    return $affiliate_token;
}

1;


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
use BOM::User::Client::PaymentNotificationQueue;
use BOM::User::Client;
use BOM::User::FinancialAssessment qw(update_financial_assessment decode_fa);
use BOM::User;
use BOM::Rules::Engine;

requires_auth('trading', 'wallet');

sub _create_oauth_token {
    my ($app_id, $loginid) = @_;
    my ($access_token) = BOM::Database::Model::OAuth->new->store_access_token_only($app_id, $loginid);
    return $access_token;
}

rpc "new_account_virtual",
    auth => [],    # unauthenticated
    sub {
    my $params = shift;
    my $args   = $params->{args};

    try {
        my ($client, $account);

        $args->{ip}          = $params->{client_ip} // '';
        $args->{country}     = uc($params->{country_code} // '');
        $args->{environment} = request()->login_env($params);
        $args->{source}      = $params->{source};

        $client  = create_virtual_account($args);
        $account = $client->default_account;

        return {
            client_id   => $client->loginid,
            email       => $client->email,
            currency    => $account->currency_code(),
            balance     => formatnumber('amount', $account->currency_code(), $account->balance),
            oauth_token => _create_oauth_token($params->{source}, $client->loginid),
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
    }
    };

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
    my $email  = lc $params->{args}->{verify_email};
    my $args   = $params->{args};
    return BOM::RPC::v3::Utility::invalid_email() unless Email::Valid->address($email);

    my $type = $params->{args}->{type};
    my $code = BOM::Platform::Token->new({
            email       => $email,
            expires_in  => 3600,
            created_for => $type,
        })->token;

    my $loginid          = $params->{token_details} ? $params->{token_details}->{loginid} : undef;
    my $extra_url_params = {};
    $extra_url_params = $args->{url_parameters} if defined $args->{url_parameters};

    return BOM::RPC::v3::Utility::invalid_params() if grep { /^pa/ } keys $extra_url_params->%* and $type ne 'paymentagent_withdraw';

    my $verification = email_verification({
        code             => $code,
        website_name     => $params->{website_name},
        verification_uri => get_verification_uri($params->{source}),
        language         => $params->{language},
        source           => $params->{source},
        app_name         => get_app_name($params->{source}),
        email            => $email,
        type             => $type,
        %$extra_url_params
    });

    my $existing_user = BOM::User->new(
        email => $email,
    );

    if ($existing_user and $existing_user->is_closed) {
        request_email($email, $verification->{closed_account}->());
        return {status => 1};
    }

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
        request_email($email, $verification->{reset_password}->());
    } elsif ($type eq 'account_opening') {
        unless ($existing_user) {
            request_email($email, $verification->{account_opening_new}->());
        } else {
            request_email($email, $verification->{account_opening_existing}->());
        }
    } elsif ($client and ($type eq 'paymentagent_withdraw' or $type eq 'payment_withdraw')) {
        my $validation_error = BOM::RPC::v3::Utility::cashier_validation($client, $type);
        return $validation_error if $validation_error;

        if (_is_impersonating_client($params->{token})) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'Permission Denied',
                    message_to_client => localize('You can not perform a withdrawal while impersonating an account')});
        }
        request_email($email, $verification->{payment_withdraw}->());
    } elsif ($existing_user and $type eq 'mt5_password_reset') {
        request_email($email, $verification->{mt5_password_reset}->());
    } elsif ($existing_user and $type eq 'trading_platform_password_reset') {
        # TODO: send email
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

=head2 _update_migrated_universal_password_existing_clients

Update migrate_universal_password of each clients for the user.

=over 4

=item * C<$clients> - list of clients

=back

Returns undef on success, otherwise return error

=cut

sub _update_migrated_universal_password_existing_clients {
    my ($clients) = @_;

    if ($clients) {
        foreach my $client (@{$clients}) {
            my $error = BOM::RPC::v3::Utility::set_migrated_universal_password_status($client);
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

rpc new_account_real => sub {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};

    $args->{client_type} //= 'retail';

    $client->residence($args->{residence}) unless $client->residence;
    my $countries_instance = request()->brand->countries_instance;

    # Send error if maltainvest client tried to make this call as they have their own call,
    # except whom has a gaming company.
    return BOM::RPC::v3::Utility::permission_error()
        if ($client->landing_company->short eq 'maltainvest' and not $countries_instance->gaming_company_for_country($client->residence));

    my $error = BOM::RPC::v3::Utility::validate_make_new_account($client, 'real', $args);
    return $error if $error;

    my $company = $countries_instance->gaming_company_for_country($client->residence)
        // $countries_instance->financial_company_for_country($client->residence);
    my $broker = LandingCompany::Registry->new->get($company)->broker_codes->[0];

    my $non_pep_declaration = delete $args->{non_pep_declaration};
    $args->{non_pep_declaration_time} = _get_non_pep_declaration_time($client, $company, $non_pep_declaration, $params->{source});
    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, $broker, $params->{source});

    my $error_map = BOM::RPC::v3::Utility::error_map();
    if ($details_ref && $details_ref->{error}) {
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

    my $lock = BOM::Platform::Redis::acquire_lock($client->user_id, 10);
    return BOM::RPC::v3::Utility::rate_limit_error() if not $lock;

    my $acc;
    try {
        $acc = BOM::Platform::Account::Real::default::create_account({
            ip          => $params->{client_ip} // '',
            country     => uc($client->residence // ''),
            from_client => $client,
            user        => $user,
            details     => $details_ref->{details},
        });
    } finally {
        BOM::Platform::Redis::release_lock($client->user_id);
    }

    if (my $err_code = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err_code,
                message_to_client => $error_map->{$err_code}});
    }

    # Updates the financial assessment for the new client, will be removed when financial assessment is moved to the user level

    update_financial_assessment($client->user, decode_fa($client->financial_assessment())) if $client->financial_assessment();

    my $new_client      = $acc->{client};
    my $landing_company = $new_client->landing_company;

    # XXX If we fail after account creation then we could end up with these flags not set,
    # ideally should be handled in a single transaction
    # as account is already created so no need to die on status set
    # else it will give false impression to client

    $error = BOM::RPC::v3::Utility::set_professional_status($new_client, $professional_status, $professional_requested);

    return $error if $error;

    if (!BOM::Config::Runtime->instance->app_config->system->suspend->universal_password && $sibling_has_migrated_universal_password_status) {
        $error = BOM::RPC::v3::Utility::set_migrated_universal_password_status($new_client);
        return $error if $error;
    }

    if ($args->{currency}) {
        my $currency_set_result = BOM::RPC::v3::Accounts::set_account_currency({
                client   => $new_client,
                currency => $args->{currency}});
        return $currency_set_result if $currency_set_result->{error};
    }

    $user->add_login_history(
        action      => 'login',
        environment => request()->login_env($params),
        successful  => 't',
        app_id      => $params->{source});

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
            properties => {type => 'real'}});

    return {
        client_id                 => $new_client->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short,
        oauth_token               => _create_oauth_token($params->{source}, $new_client->loginid),
        $args->{currency} ? (currency => $new_client->currency) : (),
    };
};

rpc new_account_maltainvest => sub {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};
    my $user = $client->user;

    $args->{client_type} //= 'retail';

    my $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        landing_company => 'maltainvest'
    );

    # send error if anyone other than maltainvest, virtual,
    # malta, iom tried to make this call
    return BOM::RPC::v3::Utility::permission_error()
        if ($client->landing_company->short !~ /^(?:virtual|malta|maltainvest|iom)$/);

    my $non_pep_declaration = delete $args->{non_pep_declaration};
    $args->{non_pep_declaration_time} = _get_non_pep_declaration_time($client, 'maltainvest', $non_pep_declaration, $params->{source});

    my $error = BOM::RPC::v3::Utility::validate_make_new_account($client, 'financial', $args, $rule_engine);
    return $error if $error;
    my $error_map = BOM::RPC::v3::Utility::error_map();

    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, 'MF', $params->{source}, $rule_engine);
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $details_ref->{error},
                message_to_client => $error_map->{$details_ref->{error}},
                details           => $details_ref->{details}});
    }

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

    my ($clients, $professional_status, $professional_requested) = _get_professional_details_clients($user, $args);

    my $val = _update_professional_existing_clients($clients, $professional_status, $professional_requested);
    return $val if $val;

    my $sibling_has_migrated_universal_password_status = any { $_->status->migrated_universal_password } $user->clients;
    if (!BOM::Config::Runtime->instance->app_config->system->suspend->universal_password && $sibling_has_migrated_universal_password_status) {
        $val = _update_migrated_universal_password_existing_clients($clients);
        return $val if $val;
    }

    try {
        $rule_engine->verify_action('new_account', {%$args, account_type => 'financial'});
    } catch ($error) {
        return BOM::RPC::v3::Utility::rule_engine_error($error);
    }

    my $acc = BOM::Platform::Account::Real::maltainvest::create_account({
        ip          => $params->{client_ip} // '',
        country     => uc($params->{country_code} // ''),
        from_client => $client,
        user        => $user,
        details     => $details_ref->{details},
        params      => $args
    });

    if (my $err_code = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err_code,
                message_to_client => $error_map->{$err_code}});
    }

    my $new_client      = $acc->{client};
    my $landing_company = $new_client->landing_company;

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
    try {
        $new_client->sync_authentication_from_siblings;
    } catch {
        return BOM::RPC::v3::Utility::client_error()
    };

    $error = BOM::RPC::v3::Utility::set_professional_status($new_client, $professional_status, $professional_requested);
    return $error if $error;

    if (!BOM::Config::Runtime->instance->app_config->system->suspend->universal_password && $sibling_has_migrated_universal_password_status) {
        $error = BOM::RPC::v3::Utility::set_migrated_universal_password_status($new_client);
        return $error if $error;
    }

    $user->add_login_history(
        action      => 'login',
        environment => request()->login_env($params),
        successful  => 't',
        app_id      => $params->{source});

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
            properties => {type => 'real'}});

    # We want to have stats of number of clients that provide wrong tax number
    my $countries_instance = request()->brand->countries_instance();
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
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short,
        oauth_token               => _create_oauth_token($params->{source}, $new_client->loginid),
    };
};

rpc 'new_account',
    auth => [],
    sub {
    my $params = shift;
    my $args   = $params->{args};

    $args->{type} = $args->{type} // 'trading';    # default to 'trading'

    my $subtype = $args->{subtype};
    return BOM::RPC::v3::Utility::create_error({
            code              => 'MissingSubtype',
            message_to_client => localize('Please specify the account subtype: "real" or "virtual"'),
        }) unless ($subtype);

    try {
        my ($client, $account);

        $args->{ip}            = $params->{client_ip} // '';
        $args->{country}       = uc($params->{country_code} // '');
        $args->{environment}   = request()->login_env($params);
        $args->{source}        = $params->{source};
        $args->{token_details} = $params->{token_details};

        # create virtual account
        if ($subtype eq 'virtual') {
            $client = create_virtual_account($args);
        } else {
            die 'Unsupported account subtype';
        }
        $account = $client->default_account;

        return {
            client_loginid => $client->loginid,
            email          => $client->email,
            currency       => $account->currency_code(),
            balance        => formatnumber('amount', $account->currency_code(), $account->balance),
            oauth_token    => _create_oauth_token($params->{source}, $client->loginid),
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
    }
    };

rpc new_account_wallet => sub {
    my $params = shift;

    my ($from_client, $args) = @{$params}{qw/client args/};
    try {

        $args->{ip}          = $params->{client_ip} // '';
        $args->{country}     = uc($params->{country_code} // '');
        $args->{environment} = request()->login_env($params);
        $args->{source}      = $params->{source};
        $args->{residence}   = $from_client->residence;

        my $response = new_wallet_real($from_client, $args);
        return $response->{error} if $response->{error};

        my $client          = $response->{wallet};
        my $account         = $client->default_account;
        my $landing_company = $client->landing_company;

        return {
            client_id                 => $client->loginid,
            landing_company           => $landing_company->name,
            landing_company_shortcode => $landing_company->short,
            oauth_token               => _create_oauth_token($params->{source}, $client->loginid),
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
    }
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

    if ($args->{token_details}) {
        # authenticated (existing user) - check for auth token
        my $user = BOM::User->new(loginid => $args->{token_details}->{loginid});
        $args->{email} = $user->{email};
    } else {
        # unauthenticated (new user) - check for verification_code

        # These required fields are excluded from JSON schema, we need to handle it here
        for my $field (qw( client_password residence verification_code )) {
            die {
                code    => 'InputValidationFailed',
                details => {field => $field}} unless ($args->{$field});
        }

        my $verification_code = $args->{verification_code};
        $args->{email} = BOM::Platform::Token->new({token => $verification_code})->email;

        $error = BOM::RPC::v3::Utility::is_verification_token_valid($verification_code, $args->{email}, 'account_opening')->{error};
        die $error if $error;

        $error = BOM::RPC::v3::Utility::check_password({
                email        => $args->{email},
                new_password => $args->{client_password}});
        die $error if $error;
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

    foreach my $k (qw( date_first_contact gclid_url signup_device utm_campaign utm_medium utm_source )) {
        $account_args->{details}->{$k} = $args->{$k} if $args->{$k};
    }

    foreach my $k (qw( utm_ad_id utm_adgroup_id utm_adrollclk_id utm_campaign_id utm_content utm_fbcl_id utm_gl_client_id utm_msclk_id utm_term )) {
        $account_args->{utm_data}->{$k} = $args->{$k} if $args->{$k};
    }

    my $account = BOM::Platform::Account::Virtual::create_account($account_args);
    die $account->{error} if $account->{error};

    if (!BOM::Config::Runtime->instance->app_config->system->suspend->universal_password) {
        $error = BOM::RPC::v3::Utility::set_migrated_universal_password_status($account->{client});
        die $error if $error;
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
    foreach my $tag (qw( date_first_contact gclid_url signup_device utm_campaign utm_content utm_medium utm_source utm_term )) {
        $utm_tags->{$tag} = $args->{$tag} if $args->{$tag};
    }

    BOM::Platform::Event::Emitter::emit(
        'signup',
        {
            loginid    => $client->loginid,
            properties => {
                type     => $args->{type},
                subtype  => 'virtual',
                utm_tags => $utm_tags
            }});

    return $client;
}

=head2 new_wallet_real

Creates a new real wallet

=over 4

=item * C<client> form client which wallet is being created
=item * C<args> new wallet details

=back

Returns a C<BOM::User::Wallet> instance

=cut

sub new_wallet_real {
    my ($client, $args) = @_;
    my $user = $client->user;
    my ($new_wallet, $error);

    # TODO Move this hardcoded logic to perl brand, we should make decisions based on the brand and country of residence
    my $broker = 'DW';
    my $type   = 'wallet';

    $args->{broker_code} = $broker;
    # has remianed from the history of design
    $args->{client_type} //= 'retail';

    my $non_pep_declaration = delete $args->{non_pep_declaration};
    $args->{non_pep_declaration_time} = _get_non_pep_declaration_time($client, 'wallet', $non_pep_declaration, $args->{source});

    my $error_map   = BOM::RPC::v3::Utility::error_map();
    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, $broker, $args->{source});
    if (my $err = $details_ref->{error}) {
        return {
            error => BOM::RPC::v3::Utility::create_error({
                    code              => $details_ref->{error},
                    message_to_client => $details_ref->{message_to_client} // $error_map->{$details_ref->{error}},
                    details           => $details_ref->{details}})};
    }

    # The method validate_account_details keeps only predefined args in its result
    $details_ref->{details}->{type}           = $type;
    $details_ref->{details}->{currency}       = $args->{currency};
    $details_ref->{details}->{payment_method} = $args->{payment_method};
    my $acc = BOM::Platform::Account::Real::default::create_account({
        ip          => $args->{ip} // '',
        country     => uc($args->{country} // ''),
        from_client => $client,
        user        => $user,
        details     => $details_ref->{details},
    });

    if (my $err_code = $acc->{error}) {
        return {
            error => BOM::RPC::v3::Utility::create_error({
                    code              => $err_code,
                    message_to_client => $error_map->{$err_code}})};
    }

    $user       = $acc->{user};
    $new_wallet = $acc->{client};

    # Not sure if the following notfications are required for wallet creation or not
    $user->add_login_history(
        action      => 'login',
        environment => $args->{environment},
        successful  => 't',
        app_id      => $args->{source});

    BOM::User::AuditLog::log("successful login", "$client->email");
    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'real',
        currency      => $args->{currency} // 'USD',
        loginid       => $new_wallet->loginid,
        type          => 'newaccount',
        amount        => 0,
        payment_agent => 0,
    );

    BOM::Platform::Event::Emitter::emit(
        'signup',
        {
            loginid    => $new_wallet->loginid,
            properties => {
                type    => $type,
                subtype => 'real'
            }});

    return {
        wallet => $new_wallet,
        error  => $error
    };
}

1;


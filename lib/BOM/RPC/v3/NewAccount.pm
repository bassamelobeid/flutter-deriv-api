package BOM::RPC::v3::NewAccount;

use strict;
use warnings;

use Try::Tiny;
use List::MoreUtils qw(any);
use Format::Util::Numbers qw/formatnumber/;
use Email::Valid;
use BOM::Platform::Context qw (localize);
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use BOM::RPC::Registry '-dsl';

use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::User::Client;

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::EmailVerification qw(email_verification);
use BOM::RPC::v3::Accounts;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Email qw(send_email);
use BOM::User;
use BOM::Config;
use BOM::Platform::Context qw (request);
use BOM::Database::Model::OAuth;
use BOM::User::Client::PaymentNotificationQueue;
use BOM::User::FinancialAssessment qw(update_financial_assessment decode_fa);

requires_auth();

sub _create_oauth_token {
    my ($app_id, $loginid) = @_;
    my ($access_token) = BOM::Database::Model::OAuth->new->store_access_token_only($app_id, $loginid);
    return $access_token;
}

rpc "new_account_virtual",
    auth => 0,    # unauthenticated
    sub {
    my $params = shift;

    my $args = $params->{args};
    my $err_code;
    if ($err_code = BOM::RPC::v3::Utility::_check_password({new_password => $args->{client_password}})) {
        return $err_code;
    }

    my $email = BOM::Platform::Token->new({token => $args->{verification_code}})->email;

    if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $email, 'account_opening')->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err->{code},
                message_to_client => $err->{message_to_client}});
    }

    my $acc = BOM::Platform::Account::Virtual::create_account({
            ip => $params->{client_ip} // '',
            country => uc($params->{country_code} // ''),
            details => {
                email           => $email,
                client_password => $args->{client_password},
                residence       => $args->{residence},
                source          => $params->{source},
                $args->{affiliate_token} ? (myaffiliates_token => $args->{affiliate_token}) : (),
                (map { $args->{$_} ? ($_ => $args->{$_}) : () } qw( utm_source utm_medium utm_campaign gclid_url date_first_contact signup_device ))
            },
        });

    return BOM::RPC::v3::Utility::create_error({
            code              => $acc->{error},
            message_to_client => BOM::RPC::v3::Utility::error_map()->{$acc->{error}}}) if $acc->{error};

    # Check if it is from UK, instantly mark it as unwelcome
    if (uc $acc->{client}->residence eq 'GB') {
        $acc->{client}->status->set('unwelcome', 'SYSTEM', 'Pending proof of age');
    }

    my $client  = $acc->{client};
    my $account = $client->default_account;
    my $user    = $acc->{user};

    BOM::Platform::Event::Emitter::emit(
        'register_details',
        {
            loginid  => $client->loginid,
            language => $params->{language}});

    $user->add_login_history(
        action      => 'login',
        environment => BOM::RPC::v3::Utility::login_env($params),
        successful  => 't'
    );

    BOM::User::AuditLog::log("successful login", "$email");
    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'virtual',
        currency      => 'USD',
        loginid       => $client->loginid,
        type          => 'newaccount',
        amount        => 0,
        payment_agent => 0,
    );

    # Welcome email for Binary brand is handled in customer.io
    # we're sending for Deriv here as a temporary solution
    # until customer.io is able to handle multiple domains
    my $brand = request()->brand;
    request_email(
        $email,
        {
            subject       => localize('Welcome to Deriv'),
            template_name => 'welcome_virtual',
        }) if $brand->name eq 'deriv';

    return {
        client_id => $client->loginid,
        email     => $email,
        currency  => $account->currency_code(),
        balance   => formatnumber('amount', $account->currency_code(), $account->balance),
        oauth_token => _create_oauth_token($params->{source}, $client->loginid),
    };
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
    auth => 0,    # unauthenticated
    sub {
    my $params = shift;

    my $email = lc $params->{args}->{verify_email};
    my $args  = $params->{args};
    return BOM::RPC::v3::Utility::invalid_email() unless Email::Valid->address($email);

    my $type = $params->{args}->{type};
    my $code = BOM::Platform::Token->new({
            email       => $email,
            expires_in  => 3600,
            created_for => $type,
        })->token;

    my $loginid = $params->{token_details} ? $params->{token_details}->{loginid} : undef;
    my $extra_url_params = {};
    $extra_url_params = $args->{url_parameters} if defined $args->{url_parameters};
    my $verification = email_verification({
        code             => $code,
        website_name     => $params->{website_name},
        verification_uri => get_verification_uri($params->{source}),
        language         => $params->{language},
        source           => $params->{source},
        app_name         => get_app_name($params->{source}),
        email            => $email,
        %$extra_url_params
    });

    my $email_already_exist = BOM::User->new(
        email => $email,
    );

    my $payment_sub = sub {
        my $type_call = shift;

        my $skip_email = 0;
        # we should only check for loginid email but as its v3 so need to have backward compatibility
        # in next version need to remove else
        if ($loginid) {
            $skip_email = 1 unless (
                BOM::User::Client->new({
                        loginid      => $loginid,
                        db_operation => 'replica'
                    }
                )->email eq $email
            );
        } else {
            $skip_email = 1 unless $email_already_exist;
        }

        request_email($email, $verification->{payment_withdraw}->($type_call)) unless $skip_email;
    };

    if ($email_already_exist and $type eq 'reset_password') {
        request_email($email, $verification->{reset_password}->());
    } elsif ($type eq 'account_opening') {
        unless ($email_already_exist) {
            request_email($email, $verification->{account_opening_new}->());
        } else {
            request_email($email, $verification->{account_opening_existing}->());
        }
    } elsif ($type eq 'paymentagent_withdraw') {
        $payment_sub->($type);
    } elsif ($type eq 'payment_withdraw') {
        $payment_sub->($type);
    } elsif ($type eq 'mt5_password_reset') {
        request_email($email, $verification->{mt5_password_reset}->());
    }

    # always return 1, so not to leak client's email
    return {status => 1};
    };

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

    $args->{client_type} //= 'retail';

    # send error if maltainvest client tried to make this call
    # as they have their own separate api call for account opening
    return BOM::RPC::v3::Utility::permission_error()
        if $client->landing_company->short eq 'maltainvest';

    $client->residence($args->{residence}) unless $client->residence;
    my $error = BOM::RPC::v3::Utility::validate_make_new_account($client, 'real', $args);
    return $error if $error;

    my $countries_instance = request()->brand->countries_instance;
    my $company            = $countries_instance->gaming_company_for_country($client->residence)
        // $countries_instance->financial_company_for_country($client->residence);
    my $broker = LandingCompany::Registry->new->get($company)->broker_codes->[0];

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
    my $acc = BOM::Platform::Account::Real::default::create_account({
        ip => $params->{client_ip} // '',
        country => uc($client->residence // ''),
        from_client => $client,
        user        => $user,
        details     => $details_ref->{details},
    });

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

    if ($args->{currency}) {
        my $currency_set_result = BOM::RPC::v3::Accounts::set_account_currency({
                client   => $new_client,
                currency => $args->{currency}});
        return $currency_set_result if $currency_set_result->{error};
    }

    BOM::Platform::Event::Emitter::emit(
        'register_details',
        {
            loginid  => $new_client->loginid,
            language => $params->{language}});

    $user->add_login_history(
        action      => 'login',
        environment => BOM::RPC::v3::Utility::login_env($params),
        successful  => 't'
    );

    if ($new_client->residence eq 'gb' or $new_client->landing_company->check_max_turnover_limit_is_set)
    {    # RTS 12 - Financial Limits - UK Clients and MLT Clients
        try { $new_client->status->set('max_turnover_limit_not_set', 'system', 'new GB client or MLT client - have to set turnover limit') }
        catch { $error = BOM::RPC::v3::Utility::client_error() };
        return $error if $error;
    }

    BOM::User::AuditLog::log("successful login", "$client->email");
    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'real',
        currency      => 'USD',
        loginid       => $new_client->loginid,
        type          => 'newaccount',
        amount        => 0,
        payment_agent => 0,
    );
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

    # send error if anyone other than maltainvest, virtual,
    # malta, iom tried to make this call
    return BOM::RPC::v3::Utility::permission_error()
        if ($client->landing_company->short !~ /^(?:virtual|malta|maltainvest|iom)$/);

    my $error = BOM::RPC::v3::Utility::validate_make_new_account($client, 'financial', $args);
    return $error if $error;

    my $error_map = BOM::RPC::v3::Utility::error_map();

    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, 'MF', $params->{source});
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $details_ref->{error},
                message_to_client => $error_map->{$details_ref->{error}},
                details           => $details_ref->{details}});
    }
    # When a Binary (Europe) Ltd/Binary (IOM) Ltd account is created,
    # the 'place of birth' field is not present.
    # After creating Binary (Europe) Ltd/Binary (IOM) Ltd account, client can select
    # their place of birth in their profile settings.
    # However, when a Binary Investments (Europe) Ltd account account is created,
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
    my $acc = BOM::Platform::Account::Real::maltainvest::create_account({
        ip => $params->{client_ip} // '',
        country => uc($params->{country_code} // ''),
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
    # However, when a Binary Investments (Europe) Ltd account is created, the citizenship
    # is not updated in the new account.
    # Hence, the following check is necessary
    $new_client->citizen($client->citizen) if ($client->citizen && !$client->is_virtual);

    # Save new account
    if (not $new_client->save) {
        stats_inc('bom_rpc.v_3.call_failure.count', {tags => ["rpc:new_account_maltainvest"]});
        return BOM::RPC::v3::Utility::client_error();

    }

    $error = BOM::RPC::v3::Utility::set_professional_status($new_client, $professional_status, $professional_requested);

    return $error if $error;

    # This is here for consistency, although it will currently do nothing because email_consent default is false for MF
    BOM::Platform::Event::Emitter::emit(
        'register_details',
        {
            loginid  => $new_client->loginid,
            language => $params->{language}});

    $user->add_login_history(
        action      => 'login',
        environment => BOM::RPC::v3::Utility::login_env($params),
        successful  => 't'
    );

    BOM::User::AuditLog::log("successful login", "$client->email");
    BOM::User::Client::PaymentNotificationQueue->add(
        source        => 'real',
        currency      => 'USD',
        loginid       => $new_client->loginid,
        type          => 'newaccount',
        amount        => 0,
        payment_agent => 0,
    );
    return {
        client_id                 => $new_client->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short,
        oauth_token               => _create_oauth_token($params->{source}, $new_client->loginid),
    };
};

1;

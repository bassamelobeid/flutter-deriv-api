package BOM::RPC::v3::NewAccount;

use strict;
use warnings;

use DateTime;
use Try::Tiny;
use List::MoreUtils qw(any);
use Format::Util::Numbers qw/formatnumber/;
use Email::Valid;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use Brands;

use Client::Account;

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::EmailVerification qw(email_verification);
use BOM::RPC::v3::Accounts;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::japan;
use BOM::Platform::Account::Real::subaccount;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::User;
use BOM::Platform::Config;
use BOM::Platform::Context::Request;
use BOM::Platform::Client::Utility;
use BOM::Platform::Context qw (request);
use BOM::Database::Model::OAuth;
use BOM::Platform::PaymentNotificationQueue;

sub _create_oauth_token {
    my $loginid = shift;
    my ($access_token) = BOM::Database::Model::OAuth->new->store_access_token_only('1', $loginid);
    return $access_token;
}

sub new_account_virtual {
    my $params = shift;
    my $args   = $params->{args};
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
                $args->{utm_source}      ? (utm_source         => $args->{utm_source})      : (),
                $args->{utm_medium}      ? (utm_medium         => $args->{utm_medium})      : (),
                $args->{utm_campaign}    ? (utm_campaign       => $args->{utm_campaign})    : (),
                $args->{gclid_url}       ? (gclid_url          => $args->{gclid_url})       : (),
                $args->{email_consent}   ? (email_consent      => $args->{email_consent})   : (),
            },
        });

    return BOM::RPC::v3::Utility::create_error({
            code              => $acc->{error},
            message_to_client => BOM::RPC::v3::Utility::error_map()->{$acc->{error}}}) if $acc->{error};

    my $client  = $acc->{client};
    my $account = $client->default_account->load;
    my $user    = $acc->{user};
    $user->add_login_history({
        action      => 'login',
        environment => BOM::RPC::v3::Utility::login_env($params),
        successful  => 't'
    });
    $user->save;

    BOM::Platform::AuditLog::log("successful login", "$email");
    BOM::Platform::PaymentNotificationQueue->add(
        source        => 'virtual',
        currency      => 'USD',
        loginid       => $client->loginid,
        type          => 'newaccount',
        amount        => 0,
        payment_agent => 0,
    );
    return {
        client_id   => $client->loginid,
        email       => $email,
        currency    => $account->currency_code,
        balance     => formatnumber('amount', $account->currency_code, $account->balance),
        oauth_token => _create_oauth_token($client->loginid),
    };
}

sub request_email {
    my ($email, $args) = @_;

    my $subject = $args->{subject};
    my $message = $args->{message};

    return send_email({
        from                  => Brands->new(name => request()->brand)->emails('support'),
        to                    => $email,
        subject               => $subject,
        message               => [$message],
        use_email_template    => 1,
        email_content_is_html => 1,
        skip_text2html        => 1,
    });
}

sub get_verification_uri {
    my $app_id = shift or return undef;
    return BOM::Database::Model::OAuth->new->get_verification_uri_by_app_id($app_id);
}

sub verify_email {
    my $params = shift;

    my $email = $params->{args}->{verify_email};
    return BOM::RPC::v3::Utility::invalid_email() if !Email::Valid->address($email);

    my $type = $params->{args}->{type};
    my $code = BOM::Platform::Token->new({
            email       => $email,
            expires_in  => 3600,
            created_for => $type,
        })->token;

    my $loginid = $params->{token_details} ? $params->{token_details}->{loginid} : undef;

    my $verification = email_verification({
        code             => $code,
        website_name     => $params->{website_name},
        verification_uri => get_verification_uri($params->{source}),
        language         => $params->{language},
    });

    my $payment_sub = sub {
        my $type_call = shift;

        my $skip_email = 0;
        # we should only check for loginid email but as its v3 so need to have backward compatibility
        # in next version need to remove else
        if ($loginid) {
            $skip_email = 1 unless (
                Client::Account->new({
                        loginid      => $loginid,
                        db_operation => 'replica'
                    }
                )->email eq $email
            );
        } else {
            $skip_email = 1 unless BOM::Platform::User->new({email => $email});
        }

        request_email($email, $verification->{payment_withdraw}->($type_call)) unless $skip_email;
    };

    if (BOM::Platform::User->new({email => $email}) && $type eq 'reset_password') {
        request_email($email, $verification->{reset_password}->());
    } elsif ($type eq 'account_opening') {
        unless (BOM::Platform::User->new({email => $email})) {
            request_email($email, $verification->{account_opening_new}->());
        } else {
            request_email($email, $verification->{account_opening_existing}->());
        }
    } elsif ($type eq 'paymentagent_withdraw') {
        $payment_sub->($type);
    } elsif ($type eq 'payment_withdraw') {
        $payment_sub->($type);
    }

    return {status => 1};    # always return 1, so not to leak client's email
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
    my @clients =
        grep { $_->landing_company->short =~ /^(?:costarica|maltainvest)$/ } map { Client::Account->new({loginid => $_->loginid}) } @{$user->loginid};

    # Get the professional flags
    my $professional_status = any { $_->get_status('professional') } @clients;
    my $professional_requested =
        !$professional_status && (($args->{client_type} eq 'professional') || any { $_->get_status('professional_requested') } @clients);

    return (\@clients, $professional_status, $professional_requested);
}

sub new_account_real {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};

    $args->{account_type} //= 'default';
    $args->{client_type}  //= 'retail';

    my $ico_only = $args->{account_type} eq 'ico';

    # send error if maltainvest and japan client tried to make this call
    # as they have their own separate api call for account opening
    return BOM::RPC::v3::Utility::permission_error()
        if ($client->landing_company->short =~ /^(?:maltainvest|japan)$/)
        and not $ico_only;

    my $error = BOM::RPC::v3::Utility::validate_make_new_account($client, 'real', $args);
    return $error if $error;

    my $residence = $client->residence;
    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;
    my $company = $countries_instance->gaming_company_for_country($residence) // $countries_instance->financial_company_for_country($residence);
    my $broker  = LandingCompany::Registry->new->get($company)->broker_codes->[0];

    # EU clients signing up for ICO get a CR account with trading disabled
    $broker = 'CR' if $ico_only;

    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, $broker, $params->{source});
    my $error_map = BOM::RPC::v3::Utility::error_map();
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err,
                message_to_client => $error_map->{$err}});
    }
    # call was done with currency flag
    if ($args->{currency}) {
        $error = BOM::RPC::v3::Utility::validate_set_currency($client, $args->{currency});
        return $error if $error;
    }

    my $user = BOM::Platform::User->new({email => $client->email});

    my ($clients, $professional_status, $professional_requested) = _get_professional_details_clients($user, $args);

    my $val = _update_professional_existing_clients($clients, $professional_status, $professional_requested);

    return $val if $val;

    my $acc = BOM::Platform::Account::Real::default::create_account({
        ip => $params->{client_ip} // '',
        country => uc($params->{country_code} // ''),
        from_client => $client,
        user        => $user,
        details     => $details_ref->{details},
    });

    if (my $err_code = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err_code,
                message_to_client => $error_map->{$err_code}});
    }

    my $new_client      = $acc->{client};
    my $landing_company = $new_client->landing_company;

    # XXX If we fail after account creation then we could end up with these flags not set,
    # ideally should be handled in a single transaction
    # as account is already created so no need to die on status set
    # else it will give false impression to client
    $new_client->set_status('ico_only', 'SYSTEM', 'ICO account requested') if $ico_only;

    $error = BOM::RPC::v3::Utility::set_professional_status($new_client, $professional_status, $professional_requested);

    return $error if $error;

    if ($args->{currency}) {
        my $currency_set_result = BOM::RPC::v3::Accounts::set_account_currency({
                client   => $new_client,
                currency => $args->{currency}});
        return $currency_set_result if $currency_set_result->{error};
    }

    $user->add_login_history({
        action      => 'login',
        environment => BOM::RPC::v3::Utility::login_env($params),
        successful  => 't'
    });
    $user->save;

    if ($new_client->residence eq 'gb' and not $ico_only) {    # RTS 12 - Financial Limits - UK Clients
        $new_client->set_status('ukrts_max_turnover_limit_not_set', 'system', 'new GB client - have to set turnover limit');

        if (not $new_client->save) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InternalServerError',
                    message_to_client => localize('Sorry, an error occurred while processing your account.')});
        }
    }

    BOM::Platform::AuditLog::log("successful login", "$client->email");
    BOM::Platform::PaymentNotificationQueue->add(
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
        oauth_token               => _create_oauth_token($new_client->loginid),
        $args->{currency} ? (currency => $new_client->currency) : (),
    };
}

sub set_details {
    my ($client, $args) = @_;

    # don't update client's brokercode with wrong value
    delete $args->{broker_code};
    $client->$_($args->{$_}) for keys %$args;

    # special cases.. force empty string if necessary in these not-nullable cols.  They oughta be nullable in the db!
    for (qw(citizen address_2 state postcode salutation)) {
        $client->$_('') unless defined $client->$_;
    }

    return $client;
}

sub new_account_maltainvest {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};

    $args->{client_type} //= 'retail';

    # send error if anyone other than maltainvest, virtual, malta
    # tried to make this call
    return BOM::RPC::v3::Utility::permission_error()
        if ($client->landing_company->short !~ /^(?:virtual|malta|maltainvest)$/);

    my $error = BOM::RPC::v3::Utility::validate_make_new_account($client, 'maltainvest', $args);
    return $error if $error;

    my $error_map = BOM::RPC::v3::Utility::error_map();

    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, 'MF', $params->{source});
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err,
                message_to_client => $error_map->{$err}});
    }

    my %financial_data = map { $_ => $args->{$_} } (keys %{BOM::Platform::Account::Real::default::get_financial_input_mapping()});

    my $user = BOM::Platform::User->new({email => $client->email});

    my ($clients, $professional_status, $professional_requested) = _get_professional_details_clients($user, $args);

    my $val = _update_professional_existing_clients($clients, $professional_status, $professional_requested);

    return $val if $val;

    my $acc = BOM::Platform::Account::Real::maltainvest::create_account({
        ip => $params->{client_ip} // '',
        country => uc($params->{country_code} // ''),
        from_client    => $client,
        user           => $user,
        details        => $details_ref->{details},
        accept_risk    => $args->{accept_risk},
        financial_data => \%financial_data,
    });

    if (my $err_code = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err_code,
                message_to_client => $error_map->{$err_code}});
    }

    my $new_client      = $acc->{client};
    my $landing_company = $new_client->landing_company;

    $error = BOM::RPC::v3::Utility::set_professional_status($new_client, $professional_status, $professional_requested);

    return $error if $error;

    $user->add_login_history({
        action      => 'login',
        environment => BOM::RPC::v3::Utility::login_env($params),
        successful  => 't'
    });
    $user->save;

    BOM::Platform::AuditLog::log("successful login", "$client->email");
    BOM::Platform::PaymentNotificationQueue->add(
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
        oauth_token               => _create_oauth_token($new_client->loginid),
    };
}

sub new_account_japan {
    my $params = shift;

    my ($client, $args) = @{$params}{qw/client args/};

    # send error if anyone other than japan, japan-virtual
    # tried to make this call
    return BOM::RPC::v3::Utility::permission_error()
        if ($client->landing_company->short !~ /^(?:japan-virtual|japan)$/);

    my $error = BOM::RPC::v3::Utility::validate_make_new_account($client, 'japan', $args);
    return $error if $error;

    my $company     = Brands->new(name => request()->brand)->countries_instance->countries_list->{'jp'}->{financial_company};
    my $broker      = LandingCompany::Registry->new->get($company)->broker_codes->[0];
    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, $broker, $params->{source});
    my $error_map   = BOM::RPC::v3::Utility::error_map();
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err,
                message_to_client => $error_map->{$err}});
    }

    my $details = $details_ref->{details};
    $details->{$_} = $args->{$_} for ('gender', 'occupation', 'daily_loss_limit');

    my %financial_data = map { $_ => $args->{$_} }
        (keys %{BOM::Platform::Account::Real::japan::get_financial_input_mapping()}, 'trading_purpose', 'hedge_asset', 'hedge_asset_amount');

    my %agreement = map { $_ => $args->{$_} } (BOM::Platform::Account::Real::japan::agreement_fields());

    my $acc = BOM::Platform::Account::Real::japan::create_account({
        ip => $params->{client_ip} // '',
        country => uc($params->{country_code} // ''),
        from_client    => $client,
        user           => BOM::Platform::User->new({email => $client->email}),
        details        => $details,
        financial_data => \%financial_data,
        agreement      => \%agreement,
    });

    if (my $err_code = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err_code,
                message_to_client => $error_map->{$err_code}});
    }

    my $new_client      = $acc->{client};
    my $landing_company = $new_client->landing_company;
    my $user            = $acc->{user};

    $user->add_login_history({
        action      => 'login',
        environment => BOM::RPC::v3::Utility::login_env($params),
        successful  => 't'
    });
    $user->save;

    BOM::Platform::AuditLog::log("successful login", "$client->email");
    BOM::Platform::PaymentNotificationQueue->add(
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
        oauth_token               => _create_oauth_token($new_client->loginid),
    };
}

sub new_sub_account {
    my $params = shift;

    my $error_map = BOM::RPC::v3::Utility::error_map();

    my $client = $params->{client};
    if ($client->is_virtual or not $client->allow_omnibus) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $args = $params->{args};

    # call populate fields as some omnibus merchant accounts may not provide their client details
    $params->{args} = BOM::Platform::Account::Real::subaccount::populate_details($client, $args);

    # we still need to call because some may provide details, some may not provide client details
    # we pass broker code of omnibus master client as we don't care about residence or any other details
    # of sub accounts as they are just for record keeping purpose
    my $details_ref =
        BOM::Platform::Account::Real::default::validate_account_details($params->{args}, $client, $client->broker_code, $params->{source});
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err,
                message_to_client => $error_map->{$err}});
    }

    my $acc = BOM::Platform::Account::Real::subaccount::create_sub_account({
        from_client => $client,
        user        => BOM::Platform::User->new({email => $client->email}),
        details     => $details_ref->{details},
    });

    if (my $err_code = $acc->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err_code,
                message_to_client => $error_map->{$err_code}});
    }

    my $new_client = $acc->{client};
    return {
        client_id                 => $new_client->loginid,
        landing_company           => $new_client->landing_company->name,
        landing_company_shortcode => $new_client->landing_company->short,
        oauth_token               => _create_oauth_token($new_client->loginid),
    };
}

1;

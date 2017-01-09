package BOM::RPC::v3::NewAccount;

use strict;
use warnings;

use DateTime;
use Try::Tiny;
use List::MoreUtils qw(any);
use Data::Password::Meter;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use Brands;
use BOM::RPC::v3::Utility;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::japan;
use BOM::Platform::Account::Real::subaccount;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::User;
use BOM::System::Config;
use BOM::Platform::Context::Request;
use BOM::Platform::Client::Utility;
use BOM::Platform::Context qw (localize request);
use BOM::Database::Model::OAuth;

sub _create_oauth_token {
    my $loginid = shift;
    my ($access_token) = BOM::Database::Model::OAuth->new->store_access_token_only('1', $loginid);
    return $access_token;
}

sub new_account_virtual {
    my $params = shift;
    my $args   = $params->{args};
    my ($err_code, $err_msg);

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

    BOM::System::AuditLog::log("successful login", "$email");
    return {
        client_id   => $client->loginid,
        email       => $email,
        currency    => $account->currency_code,
        balance     => sprintf('%.2f', $account->balance),
        oauth_token => _create_oauth_token($client->loginid),
    };
}

sub verify_email {
    my $params = shift;

    my $email = $params->{args}->{verify_email};
    my $type  = $params->{args}->{type};
    my $code  = BOM::Platform::Token->new({
            email       => $email,
            expires_in  => 3600,
            created_for => $type,
        })->token;

    my $loginid = $params->{token_details} ? $params->{token_details}->{loginid} : undef;
    my $payment_sub = sub {
        my $type_call = shift;

        my $skip_email = 0;
        # we should only check for loginid email but as its v3 so need to have backward compatibility
        # in next version need to remove else
        if ($loginid) {
            $skip_email = 1 unless (Client::Account->new({loginid => $loginid})->email eq $email);
        } else {
            $skip_email = 1 unless BOM::Platform::User->new({email => $email});
        }

        my $message =
            $type_call eq 'payment_withdraw'
            ? BOM::Platform::Context::localize(
            '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by entering the following verification token into the payment withdrawal form:<p><span style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
            $code,
            $params->{website_name})
            : BOM::Platform::Context::localize(
            '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Please help us to verify your identity by entering the following verification token into the payment agent withdrawal form:<p><span style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
            $code, $params->{website_name});

        send_email({
                from => Brands->new(name => request()->brand)->emails('support'),
                to   => $email,
                subject            => BOM::Platform::Context::localize('Verify your withdrawal request - [_1]', $params->{website_name}),
                message            => [$message],
                use_email_template => 1
            }) unless $skip_email;
    };

    if (BOM::Platform::User->new({email => $email}) && $type eq 'reset_password') {
        send_email({
                from => Brands->new(name => request()->brand)->emails('support'),
                to   => $email,
                subject => BOM::Platform::Context::localize('[_1] New Password Request', $params->{website_name}),
                message => [
                    BOM::Platform::Context::localize(
                        '<p style="line-height:200%;color:#333333;font-size:15px;">Dear Valued Customer,</p><p>Before we can help you change your password, please help us to verify your identity by entering the following verification token into the password reset form:<p><span style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                        $code,
                        $params->{website_name})
                ],
                use_email_template => 1
            });
    } elsif ($type eq 'account_opening') {
        unless (BOM::Platform::User->new({email => $email})) {
            send_email({
                    from => Brands->new(name => request()->brand)->emails('support'),
                    to   => $email,
                    subject => BOM::Platform::Context::localize('Verify your email address - [_1]', $params->{website_name}),
                    message => [
                        BOM::Platform::Context::localize(
                            '<p style="font-weight: bold;">Thanks for signing up for a virtual account!</p><p>Enter the following verification token into the form to create an account: <p><span style="background: #f2f2f2; padding: 10px; line-height: 50px;">[_1]</span></p></p><p>Enjoy trading with us on [_2].</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_2]</p>',
                            $code,
                            $params->{website_name})
                    ],
                    use_email_template => 1
                });
        } else {
            send_email({
                    from => Brands->new(name => request()->brand)->emails('support'),
                    to   => $email,
                    subject => BOM::Platform::Context::localize('A Duplicate Email Address Has Been Submitted - [_1]', $params->{website_name}),
                    message => [
                        '<div style="line-height:200%;color:#333333;font-size:15px;">'
                            . BOM::Platform::Context::localize(
                            '<p>Dear Valued Customer,</p><p>It appears that you have tried to register an email address that is already included in our system. If it was not you, simply ignore this email, or contact our customer support if you have any concerns.</p><p style="color:#333333;font-size:15px;">With regards,<br/>[_1]</p>',
                            $params->{website_name})
                            . '</div>'
                    ],
                    use_email_template => 1
                });
        }
    } elsif ($type eq 'paymentagent_withdraw') {
        $payment_sub->($type);
    } elsif ($type eq 'payment_withdraw') {
        $payment_sub->($type);
    }

    return {status => 1};    # always return 1, so not to leak client's email
}

sub new_account_real {
    my $params = shift;

    my $client = $params->{client};

    my $error_map = BOM::RPC::v3::Utility::error_map();

    unless ($client->is_virtual and (BOM::RPC::v3::Utility::get_real_acc_opening_type({from_client => $client}) || '') eq 'real') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccount',
                message_to_client => $error_map->{'invalid'}});
    }

    my $args = $params->{args};

    my $company;
    if ($args->{residence}) {
        my $countries_list = Brands->new(name => request()->brand)->countries_instance->countries_list;
        $company = $countries_list->{$args->{residence}}->{gaming_company};
        $company = $countries_list->{$args->{residence}}->{financial_company} if (not $company or $company eq 'none');
    }

    if (not $company) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'NoLandingCompany',
                message_to_client => $error_map->{'No landing company for this country'}});
    }
    my $broker = LandingCompany::Registry->new->get($company)->broker_codes->[0];

    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, $broker, $params->{source});
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err,
                message_to_client => $error_map->{$err}});
    }

    my $acc = BOM::Platform::Account::Real::default::create_account({
        from_client => $client,
        user        => BOM::Platform::User->new({email => $client->email}),
        details     => $details_ref->{details},
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

    BOM::System::AuditLog::log("successful login", "$client->email");
    return {
        client_id                 => $new_client->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short,
        oauth_token               => _create_oauth_token($new_client->loginid),
    };
}

sub new_account_maltainvest {
    my $params = shift;

    my $client = $params->{client};

    my $args      = $params->{args};
    my $error_map = BOM::RPC::v3::Utility::error_map();

    unless ($client and (BOM::RPC::v3::Utility::get_real_acc_opening_type({from_client => $client}) || '') eq 'maltainvest') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccount',
                message_to_client => $error_map->{'invalid'}});
    }

    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, 'MF', $params->{source});
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err,
                message_to_client => $error_map->{$err}});
    }

    my %financial_data = map { $_ => $args->{$_} } (keys %{BOM::Platform::Account::Real::default::get_financial_input_mapping()});

    my $acc = BOM::Platform::Account::Real::maltainvest::create_account({
        from_client    => $client,
        user           => BOM::Platform::User->new({email => $client->email}),
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
    my $user            = $acc->{user};

    $user->add_login_history({
        action      => 'login',
        environment => BOM::RPC::v3::Utility::login_env($params),
        successful  => 't'
    });
    $user->save;

    BOM::System::AuditLog::log("successful login", "$client->email");
    return {
        client_id                 => $new_client->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short,
        oauth_token               => _create_oauth_token($new_client->loginid),
    };
}

sub new_account_japan {
    my $params = shift;

    my $client    = $params->{client};
    my $error_map = BOM::RPC::v3::Utility::error_map();

    unless ($client->is_virtual and (BOM::RPC::v3::Utility::get_real_acc_opening_type({from_client => $client}) || '') eq 'japan') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccount',
                message_to_client => $error_map->{'invalid'}});
    }

    my $company = Brands->new(name => request()->brand)->countries_instance->countries_list->{'jp'}->{financial_company};

    if (not $company) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'NoLandingCompany',
                message_to_client => $error_map->{'No landing company for this country'}});
    }
    my $broker = LandingCompany::Registry->new->get($company)->broker_codes->[0];

    my $args = $params->{args};
    my $details_ref = BOM::Platform::Account::Real::default::validate_account_details($args, $client, $broker, $params->{source});
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

    BOM::System::AuditLog::log("successful login", "$client->email");
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
    };
}

1;

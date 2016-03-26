package BOM::RPC::v3::NewAccount;

use strict;
use warnings;

use DateTime;
use Try::Tiny;
use List::MoreUtils qw(any);
use Data::Password::Meter;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use BOM::RPC::v3::Utility;
use BOM::Platform::Account;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::japan;
use BOM::Platform::Locale;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::User;
use BOM::Platform::Context::Request;
use BOM::Platform::Client::Utility;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Static::Config;

sub new_account_virtual {
    my $params = shift;
    my $args   = $params->{args};
    my ($err_code, $err_msg);

    if ($err_code = BOM::RPC::v3::Utility::_check_password({new_password => $args->{client_password}})) {
        return $err_code;
    }

    if (exists $args->{affiliate_token}) {
        $args->{myaffiliates_token} = delete $args->{affiliate_token};
    }

    if (my $err = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $args->{email})->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err->{code},
                message_to_client => $err->{message_to_client}});
    }

    my $acc = BOM::Platform::Account::Virtual::create_account({
        details        => $args,
        email_verified => 1
    });

    return BOM::RPC::v3::Utility::create_error({
            code              => $acc->{error},
            message_to_client => BOM::Platform::Locale::error_map()->{$acc->{error}}}) if $acc->{error};

    my $client  = $acc->{client};
    my $account = $client->default_account->load;
    return {
        client_id => $client->loginid,
        currency  => $account->currency_code,
        balance   => $account->balance
    };
}

sub verify_email {
    my $params = shift;

    if (BOM::Platform::User->new({email => $params->{email}}) && $params->{type} eq 'reset_password') {
        send_email({
                from    => BOM::Platform::Static::Config::get_customer_support_email(),
                to      => $params->{email},
                subject => BOM::Platform::Context::localize('[_1] New Password Request', $params->{website_name}),
                message => [
                    BOM::Platform::Context::localize(
                        'Before we can help you change your password, please help us to verify your identity by clicking on the following link: '
                            . $params->{link})
                ],
                use_email_template => 1
            });
    } elsif ($params->{type} eq 'account_opening') {
        unless (BOM::Platform::User->new({email => $params->{email}})) {
            send_email({
                from               => BOM::Platform::Static::Config::get_customer_support_email(),
                to                 => $params->{email},
                subject            => BOM::Platform::Context::localize('Verify your email address - [_1]', $params->{website_name}),
                message            => [BOM::Platform::Context::localize('Your email address verification link is: ' . $params->{link})],
                use_email_template => 1
            });
        } else {
            send_email({
                    from    => BOM::Platform::Static::Config::get_customer_support_email(),
                    to      => $params->{email},
                    subject => BOM::Platform::Context::localize('A Duplicate Email Address Has Been Submitted - [_1]', $params->{website_name}),
                    message => [
                        BOM::Platform::Context::localize(
                            'Dear Valued Customer, <p style="margin-top:1em;line-height:200%;">It appears that you have tried to register an email address that is already included in our system. If it was not you, simply ignore this email, or contact our customer support if you have any concerns.</p>'
                        )
                    ],
                    use_email_template => 1
                });
        }
    } elsif ($params->{type} eq 'paymentagent_withdraw' && BOM::Platform::User->new({email => $params->{email}})) {
        send_email({
                from    => BOM::Platform::Static::Config::get_customer_support_email(),
                to      => $params->{email},
                subject => BOM::Platform::Context::localize('Verify your withdrawal request - [_1]', $params->{website_name}),
                message => [
                    BOM::Platform::Context::localize(
                        '<p>Dear Valued Customer,</p><p>In order to verify your withdrawal request, please click on the following link: </p><p> '
                            . $params->{link} . ' </p>'
                    )
                ],
                use_email_template => 1
            });
    }

    return {status => 1};    # always return 1, so not to leak client's email
}

sub new_account_real {
    my $params = shift;

    my $token_details = BOM::RPC::v3::Utility::get_token_details($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $response  = 'new_account_real';
    my $error_map = BOM::Platform::Locale::error_map();

    unless ($client->is_virtual and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'real') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccount',
                message_to_client => $error_map->{'invalid'}});
    }

    my $args = $params->{args};
    my $details_ref =
        _get_client_details($args, $client, BOM::Platform::Context::Request->new(country_code => $args->{residence})->real_account_broker->code);
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err->{code},
                message_to_client => $err->{message}});
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

    my $landing_company = $acc->{client}->landing_company;
    return {
        client_id                 => $acc->{client}->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short
    };
}

sub new_account_maltainvest {
    my $params = shift;

    my $token_details = BOM::RPC::v3::Utility::get_token_details($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $response  = 'new_account_maltainvest';
    my $args      = $params->{args};
    my $error_map = BOM::Platform::Locale::error_map();

    unless ($client and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'maltainvest') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccount',
                message_to_client => $error_map->{'invalid'}});
    }

    my $details_ref = _get_client_details($args, $client, 'MF');
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err->{code},
                message_to_client => $err->{message}});
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

    my $landing_company = $acc->{client}->landing_company;
    return {
        client_id                 => $acc->{client}->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short
    };
}

sub new_account_japan {
    my $params = shift;

    my $token_details = BOM::RPC::v3::Utility::get_token_details($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $response  = 'new_account_japan';
    my $error_map = BOM::Platform::Locale::error_map();

    unless ($client->is_virtual and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'japan') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccount',
                message_to_client => $error_map->{'invalid'}});
    }

    my $args = $params->{args};
    my $details_ref = _get_client_details($args, $client, BOM::Platform::Context::Request->new(country_code => 'jp')->real_account_broker->code);
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => $err->{code},
                message_to_client => $err->{message}});
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

    my $landing_company = $acc->{client}->landing_company;
    return {
        client_id                 => $acc->{client}->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short
    };
}

sub _get_client_details {
    my ($args, $client, $broker) = @_;

    my $details = {
        broker_code                   => $broker,
        email                         => $client->email,
        client_password               => $client->password,
        myaffiliates_token_registered => 0,
        checked_affiliate_exposures   => 0,
        source                        => 'websocket-api',
        latest_environment            => ''
    };

    my $affiliate_token;
    $affiliate_token = delete $args->{affiliate_token} if (exists $args->{affiliate_token});
    $details->{myaffiliates_token} = $affiliate_token || $client->myaffiliates_token || '';

    my @fields = qw(salutation first_name last_name date_of_birth residence address_line_1 address_line_2
        address_city address_state address_postcode phone secret_question secret_answer);

    if ($args->{date_of_birth} and $args->{date_of_birth} =~ /^(\d{4})-(\d\d?)-(\d\d?)$/) {
        try {
            my $dob = DateTime->new(
                year  => $1,
                month => $2,
                day   => $3,
            );
            $args->{date_of_birth} = $dob->ymd;
        }
        catch { return; } or return {error => 'invalid DOB'};
    }

    foreach my $key (@fields) {
        my $value = $args->{$key};
        $value = BOM::Platform::Client::Utility::encrypt_secret_answer($value) if ($key eq 'secret_answer' and $value);

        if (not $client->is_virtual) {
            $value ||= $client->$key;
        }
        $details->{$key} = $value || '';

        # Japan real a/c has NO salutation
        next if (any { $key eq $_ } qw(address_line_2 address_state address_postcode salutation));
        return {
            error => {
                code    => 'InsufficientAccountDetails',
                message => localize('Please provide complete details for account opening.')}}
            if (not $details->{$key});
    }
    return {details => $details};
}

1;

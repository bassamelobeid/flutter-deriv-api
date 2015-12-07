package BOM::WebSocketAPI::v3::NewAccount;

use strict;
use warnings;

use DateTime;
use Try::Tiny;
use List::MoreUtils qw(any);
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use BOM::WebSocketAPI::v3::Utility;
use BOM::Platform::Account;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Locale;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::User;
use BOM::Platform::Context::Request;
use BOM::Platform::Client::Utility;
use BOM::Platform::Context qw (localize);

sub new_account_virtual {
    my ($args, $token, $email) = @_;

    my %details = %{$args};

    my $err_code;
    if (_is_session_cookie_valid($token, $email)) {
        my $acc = BOM::Platform::Account::Virtual::create_account({
            details        => \%details,
            email_verified => 1
        });
        if (not $acc->{error}) {
            my $client  = $acc->{client};
            my $account = $client->default_account->load;

            return {
                client_id => $client->loginid,
                currency  => $account->currency_code,
                balance   => $account->balance
            };
        }
        $err_code = $acc->{error};
    } else {
        $err_code = 'email unverified';
    }

    return BOM::WebSocketAPI::v3::Utility::create_error({
            code              => $err_code,
            message_to_client => BOM::Platform::Locale::error_map()->{$err_code}});
}

sub _is_session_cookie_valid {
    my ($token, $email) = @_;
    my $session_cookie = BOM::Platform::SessionCookie->new({token => $token});
    unless ($session_cookie and $session_cookie->email and $session_cookie->email eq $email) {
        return 0;
    }

    return 1;
}

sub verify_email {
    my ($email, $website, $link) = @_;
    unless (BOM::Platform::User->new({email => $email})) {
        send_email({
            from               => $website->config->get('customer_support.email'),
            to                 => $email,
            subject            => BOM::Platform::Context::localize('Verify your email address - [_1]', $website->display_name),
            message            => [BOM::Platform::Context::localize('Your email address verification code is: ' . $link)],
            use_email_template => 1
        });
    }

    return {status => 1};    # always return 1, so not to leak client's email
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
        latest_environment            => '',
        myaffiliates_token            => $client->myaffiliates_token || ''
    };

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

        next if (any { $key eq $_ } qw(address_line_2 address_state address_postcode));
        return {error => 'invalid'} if (not $details->{$key});
    }
    return {details => $details};
}

sub new_account_real {
    my ($client, $args) = @_;

    my $response  = 'new_account_real';
    my $error_map = BOM::Platform::Locale::error_map();

    unless ($client and $client->is_virtual and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'real') {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'invalid',
                message_to_client => $error_map->{'invalid'}});
    }

    my $details_ref =
        _get_client_details($args, $client, BOM::Platform::Context::Request->new(country_code => $args->{residence})->real_account_broker->code);
    if (my $err = $details_ref->{error}) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => $err,
                message_to_client => $error_map->{$err}});
    }

    my $acc = BOM::Platform::Account::Real::default::create_account({
        from_client => $client,
        user        => BOM::Platform::User->new({email => $client->email}),
        details     => $details_ref->{details},
    });

    if (my $err_code = $acc->{error}) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
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
    my ($client, $args) = @_;

    my $response  = 'new_account_maltainvest';
    my $error_map = BOM::Platform::Locale::error_map();

    unless ($args->{accept_risk} == 1
        and $client
        and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'maltainvest')
    {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'invalid',
                message_to_client => $error_map->{'invalid'}});
    }

    my $details_ref = _get_client_details($args, $client, 'MF');
    if (my $err = $details_ref->{error}) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => $err,
                message_to_client => $error_map->{$err}});
    }

    my $financial_data = {};
    $financial_data->{$_} = $args->{$_} for qw (
        forex_trading_experience forex_trading_frequency indices_trading_experience indices_trading_frequency
        commodities_trading_experience commodities_trading_frequency stocks_trading_experience stocks_trading_frequency
        other_derivatives_trading_experience other_derivatives_trading_frequency other_instruments_trading_experience
        other_instruments_trading_frequency employment_industry education_level income_source net_income estimated_worth );

    my $acc = BOM::Platform::Account::Real::maltainvest::create_account({
        from_client    => $client,
        user           => BOM::Platform::User->new({email => $client->email}),
        details        => $details_ref->{details},
        accept_risk    => 1,
        financial_data => $financial_data,
    });

    if (my $err_code = $acc->{error}) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
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

1;

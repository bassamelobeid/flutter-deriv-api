package BOM::RPC::v3::NewAccount;

use strict;
use warnings;

use DateTime;
use Try::Tiny;
use List::MoreUtils qw(any);
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use BOM::RPC::v3::Utility;
use BOM::Platform::Account;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Account::Real::maltainvest;
use BOM::Platform::Account::Real::japan;
use BOM::Platform::Locale;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::User;
use BOM::Platform::Context::Request;
use BOM::Platform::Client::Utility;
use BOM::Platform::Context qw (localize request);
use Data::Password::Meter;
use Digest::MD5 qw(md5_hex);
use BOM::System::Chronicle;

sub new_account_virtual {
    my $params = shift;
    my $args   = $params->{args};

    BOM::Platform::Context::request()->language($params->{language});

    my $err_code;
    my $pwdm = Data::Password::Meter->new(14);

    unless ($pwdm->strong($args->{client_password})) {
        $err_code = 'Password is not strong enough.';
        return BOM::RPC::v3::Utility::create_error({
                code              => $err_code,
                message_to_client => BOM::Platform::Locale::error_map()->{$err_code}});
    }

    if (exists $args->{affiliate_token}) {
        $args->{myaffiliates_token} = delete $args->{affiliate_token};
    }

    if (_is_session_cookie_valid($params->{token}, $args->{email})) {
        my $acc = BOM::Platform::Account::Virtual::create_account({
            details        => $args,
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

    return BOM::RPC::v3::Utility::create_error({
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
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    if ($params->{type} eq 'lost_password') {
        my $pwd_attempt_key = 'USER::PWD_ATTEMPT_KEY::' . md5_hex($params->{email});
        my $pwd_attempt_count = BOM::System::Chronicle->_redis_read->get($pwd_attempt_key) || 0;

        if ($pwd_attempt_count > 6) {
            my $error_map = BOM::Platform::Locale::error_map();
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'too many requests',
                    message_to_client => $error_map->{'too many request'}}); 
        } elsif (BOM::Platform::User->new({email => $params->{email}})) {
            BOM::System::Chronicle->_redis_write->incr($pwd_attempt_key);
            BOM::System::Chronicle->_redis_write->expire($pwd_attempt_key, 600) if (BOM::System::Chronicle->_redis_read->ttl($pwd_attempt_key) == -1);
            send_email({
                    from    => $params->{cs_email},
                    to      => $params->{email},
                    subject => BOM::Platform::Context::localize('[_1] New Password Request', $params->{website_name}),
                    message => [
                        BOM::Platform::Context::localize(
                            'Before we can help you change your password, please help us to verify your identity by clicking on the following link: ' . $params->{link})
                    ],
                    use_email_template => 1
                });
        }
    } elsif ($params->{type} eq 'account_opening') {
        my $verify_attempt_key = 'USER::VERIFY_ATTEMPT_KEY::' . md5_hex($params->{email});
        my $verify_attempt_count = BOM::System::Chronicle->_redis_read->get($verify_attempt_key) || 0;
        
        if ($verify_attempt_count > 6) {
            my $error_map = BOM::Platform::Locale::error_map();
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'too many requests',
                    message_to_client => $error_map->{'too many request'}});
        } else {
            BOM::System::Chronicle->_redis_write->incr($verify_attempt_key);
            BOM::System::Chronicle->_redis_write->expire($verify_attempt_key, 600) if (BOM::System::Chronicle->_redis_read->ttl($verify_attempt_key) == -1);

            if (BOM::Platform::User->new({email => $params->{email}})) {
                send_email({
                    from               => $params->{cs_email},
                    to                 => $params->{email},
                    subject            => BOM::Platform::Context::localize('A Duplicate Email Address Has Been Submitted - [_1]', $params->{website_name}),
                    message            => [BOM::Platform::Context::localize('It appears that you have just tried to register an email address that is already included in our system.<br><ul><li><strong>Forgot your password?</strong> Please visit our [_1]Lost Password Page</a> to retrieve it.</li><li><strong>It was not you?</strong> Simply ignore this email, or contact [_2]Customer Support</a>if you have any concerns.</li></ul><br>Thanks for visiting [_3][_4]</a>!', $params->{lost_pwd}, $params->{contact}, $params->{home}, $params->{website_name})],
                    use_email_template => 1
                }); 
            } else {
                send_email({
                    from               => $params->{cs_email},
                    to                 => $params->{email},
                    subject            => BOM::Platform::Context::localize('Verify your email address - [_1]', $params->{website_name}),
                    message            => [BOM::Platform::Context::localize('Your email address verification link is: ' . $params->{link})],
                    use_email_template => 1
                });
            }
        }
    }
    return {status => 1};    # always return 1, so not to leak client's email
}

sub new_account_real {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $response  = 'new_account_real';
    my $error_map = BOM::Platform::Locale::error_map();

    unless ($client->is_virtual and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'real') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'invalid',
                message_to_client => $error_map->{'invalid'}});
    }

    my $args = $params->{args};
    my $details_ref =
        _get_client_details($args, $client, BOM::Platform::Context::Request->new(country_code => $args->{residence})->real_account_broker->code);
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

    my $landing_company = $acc->{client}->landing_company;
    return {
        client_id                 => $acc->{client}->loginid,
        landing_company           => $landing_company->name,
        landing_company_shortcode => $landing_company->short
    };
}

sub new_account_maltainvest {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $response  = 'new_account_maltainvest';
    my $args      = $params->{args};
    my $error_map = BOM::Platform::Locale::error_map();

    unless ($args->{accept_risk} == 1
        and $client
        and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'maltainvest')
    {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'invalid',
                message_to_client => $error_map->{'invalid'}});
    }

    my $details_ref = _get_client_details($args, $client, 'MF');
    if (my $err = $details_ref->{error}) {
        return BOM::RPC::v3::Utility::create_error({
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

    BOM::Platform::Context::request()->language($params->{language});

    my $args = $params->{args};
    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    return BOM::RPC::v3::Utility::permission_error() unless $client;

    my $response  = 'new_account_japan';
    my $error_map = BOM::Platform::Locale::error_map();

    unless ($client->is_virtual and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'japan') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'invalid',
                message_to_client => $error_map->{'invalid'}});
    }

    my $details_ref = _get_client_details($args, $client, BOM::Platform::Context::Request->new(country_code => 'jp')->real_account_broker->code);
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
        return {error => 'invalid'} if (not $details->{$key});
    }
    return {details => $details};
}

1;

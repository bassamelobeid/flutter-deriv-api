package BOM::RPC::v3::NewAccount;

use strict;
use warnings;

use JSON qw(from_json encode_json);
use Date::Utility;
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
use BOM::Platform::Runtime;
use BOM::System::AuditLog;
use BOM::Platform::Email qw(send_email);

sub new_account_virtual {
    my $params = shift;
    my $args   = $params->{args};
    my $err_code;

    if ($err_code = BOM::RPC::v3::Utility::_check_password({new_password => $args->{client_password}})) {
        return $err_code;
    }

    if (exists $args->{affiliate_token}) {
        $args->{myaffiliates_token} = delete $args->{affiliate_token};
    }

    if (BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $args->{email})) {
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

sub verify_email {
    my $params = shift;

    if (BOM::Platform::User->new({email => $params->{email}}) && $params->{type} eq 'lost_password') {
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

    my $client_loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client_loginid;

    my $client = BOM::Platform::Client->new({loginid => $client_loginid});
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

    my $client_loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client_loginid;

    my $client = BOM::Platform::Client->new({loginid => $client_loginid});
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

    my %financial_data = map { $_ => $args->{$_} } (keys %{BOM::Platform::Account::Real::default::get_financial_input_mapping()});

    my $acc = BOM::Platform::Account::Real::maltainvest::create_account({
        from_client    => $client,
        user           => BOM::Platform::User->new({email => $client->email}),
        details        => $details_ref->{details},
        accept_risk    => 1,
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

    my $client_loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client_loginid;

    my $client = BOM::Platform::Client->new({loginid => $client_loginid});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $response  = 'new_account_japan';
    my $error_map = BOM::Platform::Locale::error_map();

    unless ($client->is_virtual and (BOM::Platform::Account::get_real_acc_opening_type({from_client => $client}) || '') eq 'japan') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'invalid',
                message_to_client => $error_map->{'invalid'}});
    }

    my $args = $params->{args};
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

sub jp_knowledge_test {
    my $params = shift;

    my $client_loginid = BOM::RPC::v3::Utility::token_to_loginid($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $client_loginid;

    my $client = BOM::Platform::Client->new({loginid => $client_loginid});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $user = BOM::Platform::User->new({ email => $client->email });
    my @siblings = $user->clients(disabled_ok => 1);
    my $jp_client = $siblings[0];

    # only allowed for VRTJ client, upgrading to JP
    unless (@siblings > 1
            and BOM::Platform::Runtime->instance->broker_codes->landing_company_for($client->broker)->short eq 'japan-virtual'
            and BOM::Platform::Runtime->instance->broker_codes->landing_company_for($jp_client->broker)->short eq 'japan'
    ) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $now = Date::Utility->new;
    my ($client_status, $status_ok);

    if ($client_status = $jp_client->get_status('jp_knowledge_test_pending')) {
        # client haven't taken any test before
        $status_ok = 1;
    } elsif ($client_status = $jp_client->get_status('jp_knowledge_test_fail')) {
        # can't take test more than once per day
        my $last_test_date = Date::Utility->new($client_status->last_modified_date);

        if ($now->days_between($last_test_date) <= 0) {
            return BOM::RPC::v3::Utility::create_error({
                code              => 'AttemptExceeded',
                message_to_client => localize('You have exceeded attempt limit for Japan knowledge test today, please try again tomorrow.'),
            });
        }
        $status_ok = 1;
    }

    unless ($status_ok) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'NotEligible',
            message_to_client => localize('You are not eligible for Japan knowledge test.'),
        });
    }

    my $args             = $params->{args};
    my ($score, $status) = @{$args}{'score', 'status'};

    if ($status eq 'pass') {
        $jp_client->clr_status($client_status->status_code);
        $jp_client->set_status('jp_activation_pending', 'system', 'pending verification documents from client.');
    } else {
        $jp_client->clr_status($client_status->status_code) if ($client_status->status_code eq 'jp_knowledge_test_pending');
        $jp_client->set_status('jp_knowledge_test_fail', 'system', "Failed test with score: $score.", $now->datetime_ddmmmyy_hhmmss);
    }

    # append result in financial_assessment record
    my $financial_data = from_json($jp_client->financial_assessment->data);

    my $results = $financial_data->{jp_knowledge_test} // [];
    push @{$results}, {
            score    => $score,
            status   => $status,
            datetime => $now->datetime_ddmmmyy_hhmmss,
        };
    $financial_data->{jp_knowledge_test} = $results;
    $client->financial_assessment({ data => encode_json($financial_data) });

    if (not $jp_client->save()) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InternalServerError',
                message_to_client => localize('Sorry, an error occurred while processing your request.')});
    }

    if ($status eq 'pass') {
        send_email({
            from               => BOM::Platform::Static::Config::get_customer_support_email(),
            to                 => $client->email,
            subject            => localize('Please send us documents for verification.'),
            message            => [localize('Please reply to this email to send us documents for verification.')],
            use_email_template => 1,
        });
        BOM::System::AuditLog::log('Japan Knowledge Test pass for ' . $jp_client->loginid . ' . System email sent to request for docs.', $client->loginid);
    }

    return { test_taken_epoch => $now->epoch };
}

1;

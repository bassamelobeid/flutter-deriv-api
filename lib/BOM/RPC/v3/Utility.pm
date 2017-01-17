package BOM::RPC::v3::Utility;

use strict;
use warnings;

use Date::Utility;
use YAML::XS qw(LoadFile);
use DataDog::DogStatsd::Helper qw(stats_inc);
use List::MoreUtils qw(any);
use Brands;

use BOM::Database::Model::AccessToken;
use BOM::Database::Model::OAuth;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Runtime;
use BOM::Platform::Token;

# Seconds between reloads of the rate_limitations.yml file.
# We don't want to reload too frequently, since we may see a lot of `website_status` calls.
# However, it's a config file held outside the repo, so we also don't want to let it get too old.
use constant RATES_FILE_CACHE_TIME => 120;

sub get_token_details {
    my $token = shift;

    return unless $token;

    my ($loginid, $creation_time, $epoch, $ua_fingerprint, @scopes);
    if (length $token == 15) {    # access token
        my $m = BOM::Database::Model::AccessToken->new;
        ($loginid, $creation_time) = $m->get_loginid_by_token($token);
        return unless $loginid;
        $epoch = Date::Utility->new($creation_time)->epoch if $creation_time;
        @scopes = $m->get_scopes_by_access_token($token);
    } elsif (length $token == 32 && $token =~ /^a1-/) {
        my $m = BOM::Database::Model::OAuth->new;
        ($loginid, $creation_time, $ua_fingerprint) = $m->get_loginid_by_access_token($token);
        return unless $loginid;
        $epoch = Date::Utility->new($creation_time)->epoch if $creation_time;
        @scopes = $m->get_scopes_by_access_token($token);
    } else {
        # invalid token type
        return;
    }

    return {
        loginid        => $loginid,
        scopes         => \@scopes,
        epoch          => $epoch,
        ua_fingerprint => $ua_fingerprint,
    };
}

sub create_error {
    my $args = shift;
    stats_inc("bom_rpc.v_3.error", {tags => ['code:' . $args->{code},]});
    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{continue_price_stream} ? (continue_price_stream => $args->{continue_price_stream}) : (),
            $args->{message}               ? (message               => $args->{message})               : (),
            $args->{details}               ? (details               => $args->{details})               : ()}};
}

sub invalid_token_error {
    return create_error({
            code              => 'InvalidToken',
            message_to_client => localize('The token is invalid.')});
}

sub permission_error {
    return create_error({
            code              => 'PermissionDenied',
            message_to_client => localize('Permission denied.')});
}

# Start this at zero to ensure we always load on first call.
my $rates_file_last_load = 0;
my $rates_file_content;

sub site_limits {

    my $now = time;
    if ($now - $rates_file_last_load > RATES_FILE_CACHE_TIME) {
        $rates_file_content = LoadFile($ENV{BOM_TEST_RATE_LIMITATIONS} // '/etc/rmg/perl_rate_limitations.yml');
        $rates_file_last_load = $now;
    }

    my $limits;
    $limits->{max_proposal_subscription} = {
        'applies_to' => 'subscribing to proposal concurrently',
        'max'        => 5
    };
    $limits->{'max_requestes_general'} = {
        'applies_to' => 'rest of calls',
        'minutely'   => $rates_file_content->{websocket_call}->{'1m'},
        'hourly'     => $rates_file_content->{websocket_call}->{'1h'}};
    $limits->{'max_requests_outcome'} = {
        'applies_to' => 'portfolio, statement and proposal',
        'minutely'   => $rates_file_content->{websocket_call_expensive}->{'1m'},
        'hourly'     => $rates_file_content->{websocket_call_expensive}->{'1h'}};
    $limits->{'max_requests_pricing'} = {
        'applies_to' => 'proposal and proposal_open_contract',
        'minutely'   => $rates_file_content->{websocket_call_pricing}->{'1m'},
        'hourly'     => $rates_file_content->{websocket_call_pricing}->{'1h'}};
    return $limits;
}

sub website_name {
    my $server_name = shift;

    return "Binary$server_name.com" if ($server_name =~ /^qa\d+$/);

    return Brands->new(name => request()->brand)->website_name;
}

sub check_authorization {
    my $client = shift;

    return create_error({
            code              => 'AuthorizationRequired',
            message_to_client => localize('Please log in.')}) unless $client;

    return create_error({
            code              => 'DisabledClient',
            message_to_client => localize('This account is unavailable.')}) if $client->get_status('disabled');

    if (my $lim = $client->get_self_exclusion_until_dt) {
        return create_error({
                code              => 'ClientSelfExclusion',
                message_to_client => localize('Sorry, you have excluded yourself until [_1].', $lim)});
    }

    return;
}

sub is_verification_token_valid {
    my ($token, $email, $created_for) = @_;

    my $verification_token = BOM::Platform::Token->new({token => $token});
    my $response = create_error({
            code              => "InvalidToken",
            message_to_client => localize('Your token has expired or is invalid.')});

    return $response unless ($verification_token and $verification_token->token);

    unless ($verification_token->{created_for} eq $created_for) {
        $verification_token->delete_token;
        return $response;
    }

    if ($verification_token->email and $verification_token->email eq $email) {
        $response = {status => 1};
    } else {
        $response = create_error({
                code              => 'InvalidEmail',
                message_to_client => localize('Email address is incorrect.')});
    }
    $verification_token->delete_token;

    return $response;
}

sub _check_password {
    my $message;
    my $args         = shift;
    my $new_password = $args->{new_password};
    if (keys %$args == 3) {
        my $old_password = $args->{old_password};
        my $user_pass    = $args->{user_pass};

        return BOM::RPC::v3::Utility::create_error({
                code              => 'PasswordError',
                message_to_client => localize('Old password is wrong.')}) if (not BOM::System::Password::checkpw($old_password, $user_pass));

        return BOM::RPC::v3::Utility::create_error({
                code              => 'PasswordError',
                message_to_client => localize('New password is same as old password.')}) if ($new_password eq $old_password);
    }
    return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordError',
            message_to_client => localize('Password is not strong enough.')}) if (not Data::Password::Meter->new(14)->strong($new_password));

    return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordError',
            message_to_client => localize('Password should be at least six characters, including lower and uppercase letters with numbers.')}
    ) if (length($new_password) < 6 or $new_password !~ /[0-9]+/ or $new_password !~ /[a-z]+/ or $new_password !~ /[A-Z]+/);

    return;
}

sub login_env {
    my $params = shift;

    my $now                = Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ;
    my $ip_address         = $params->{client_ip} || '';
    my $ip_address_country = $params->{country_code} ? uc $params->{country_code} : '';
    my $lang               = $params->{language} ? uc $params->{language} : '';
    my $ua                 = $params->{user_agent} || '';
    my $environment        = "$now IP=$ip_address IP_COUNTRY=$ip_address_country User_AGENT=$ua LANG=$lang";
    return $environment;
}

sub mask_app_id {
    my ($id, $time) = @_;

    # this is the date when we started populating source with app_id, before this
    # there were random numbers so don't want to send them back
    $id = undef if ($time and Date::Utility->new($time)->is_before(Date::Utility->new("2016-03-01")));

    return $id;
}

sub error_map {
    return {
        'email unverified'    => localize('Your email address is unverified.'),
        'pricing error'       => localize('Unable to price the contract.'),
        'no residence'        => localize('Your account has no country of residence.'),
        'invalid'             => localize('Sorry, account opening is unavailable.'),
        'invalid residence'   => localize('Sorry, our service is not available for your country of residence.'),
        'invalid UK postcode' => localize('Postcode is required for UK residents.'),
        'invalid PO Box'      => localize('P.O. Box is not accepted in address.'),
        'invalid DOB'         => localize('Your date of birth is invalid.'),
        'duplicate email'     => localize(
            'Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.'
        ),
        'duplicate name DOB' => localize(
            'Sorry, you seem to already have a real money account with us. Perhaps you have used a different email address when you registered it. For legal reasons we are not allowed to open multiple real money accounts per person.'
        ),
        'too young'            => localize('Sorry, you are too young to open an account.'),
        'show risk disclaimer' => localize('Please agree to the risk disclaimer before proceeding.'),
        'insufficient score'   => localize(
            'Unfortunately your answers to the questions above indicate that you do not have sufficient financial resources or trading experience to be eligible to open a trading account at this time.'
        ),
        'InvalidDateOfBirth'         => localize('Date of birth is invalid'),
        'InsufficientAccountDetails' => localize('Please provide complete details for account opening.')};
}

sub get_real_acc_opening_type {
    my $args        = shift;
    my $from_client = $args->{from_client};

    return unless ($from_client->residence);
    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;
    my $gaming_company     = $countries_instance->gaming_company_for_country($from_client->residence);
    my $financial_company  = $countries_instance->financial_company_for_country($from_client->residence);

    if ($from_client->is_virtual) {
        return 'real' if ($gaming_company);

        if ($financial_company) {
            # Eg: Germany, Japan
            return $financial_company if (any { $_ eq $financial_company } qw(maltainvest japan));

            # Eg: Singapore has no gaming_company
            return 'real';
        }
    } else {
        # MLT upgrade to MF
        return $financial_company if ($financial_company eq 'maltainvest');
    }
    return;
}

sub round_amount {
    my $currency = shift;
    my $amount   = shift || 0;

    if ($currency eq 'USD' || $currency eq 'AUD' || $currency eq 'GBP' || $currency eq 'EUR') {
        return sprintf('%.2f', $amount);
    } elsif ($currency eq 'JPY') {
        return sprintf('%.0f', $amount);
    } elsif ($currency eq 'XBT') {
        return sprintf('%.8f', $amount);
    } else {
        die "wrong currency for rounding [$currency]";
    }
}

1;

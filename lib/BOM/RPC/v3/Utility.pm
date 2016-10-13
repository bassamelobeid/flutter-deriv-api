package BOM::RPC::v3::Utility;

use strict;
use warnings;

use RateLimitations;
use Date::Utility;

use BOM::Database::Model::AccessToken;
use BOM::Database::Model::OAuth;
use BOM::Platform::Context qw (localize);
use BOM::Platform::Runtime;
use BOM::Platform::Token;
use DataDog::DogStatsd::Helper qw(stats_inc);

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

sub site_limits {
    my @services = RateLimitations::rate_limited_services;
    my $limits;
    $limits->{max_proposal_subscription} = {
        'applies_to' => 'subscribing to proposal concurrently',
        'max'        => 5
    };
    my @l = RateLimitations::rate_limits_for_service('websocket_call');
    $limits->{'max_requestes_general'} = {
        'applies_to' => 'rest of calls',
        'minutely'   => $l[0]->[1],
        'hourly'     => $l[1]->[1]};
    @l = RateLimitations::rate_limits_for_service('websocket_call_expensive');
    $limits->{'max_requests_outcome'} = {
        'applies_to' => 'portfolio, statement and proposal',
        'minutely'   => $l[0]->[1],
        'hourly'     => $l[1]->[1]};
    @l = RateLimitations::rate_limits_for_service('websocket_call_pricing');
    $limits->{'max_requests_pricing'} = {
        'applies_to' => 'proposal and proposal_open_contract',
        'minutely'   => $l[0]->[1],
        'hourly'     => $l[1]->[1]};
    return $limits;
}

sub website_name {
    my $server_name = shift;

    return 'Binary' . ($server_name =~ /^qa\d+$/ ? $server_name : '') . '.com';
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
    my $ip_address_country = $params->{country} ? uc $params->{country} : '';
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

1;

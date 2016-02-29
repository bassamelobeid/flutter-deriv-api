package BOM::RPC::v3::Utility;

use strict;
use warnings;

use RateLimitations;
use Date::Utility;

use BOM::Database::Model::AccessToken;
use BOM::Database::Model::OAuth;
use BOM::Platform::Context qw (localize);
use BOM::Platform::Runtime;
use BOM::Platform::SessionCookie;

sub token_to_loginid {
    my $token = shift;

    return unless $token;

    my $loginid;
    my @scopes = qw/read trade admin payments/;    # scopes is everything for session token
    if (length $token == 15) {                     # access token
        my $m = BOM::Database::Model::AccessToken->new;
        $loginid = $m->get_loginid_by_token($token);
        return unless $loginid;
        @scopes = $m->get_scopes_by_access_token($token);
    } elsif (length $token == 32 && $token =~ /^a1-/) {
        my $m = BOM::Database::Model::OAuth->new;
        $loginid = $m->get_loginid_by_access_token($token);
        return unless $loginid;
        @scopes = $m->get_scopes_by_access_token($token);
    } else {
        my $session = BOM::Platform::SessionCookie->new(token => $token);
        return unless $session and $session->validate_session;
        $loginid = $session->loginid;
    }

    return wantarray ? ($loginid, @scopes) : $loginid;    # backwards
}

sub create_error {
    my $args = shift;
    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{message} ? (message => $args->{message}) : (),
            $args->{details} ? (details => $args->{details}) : ()}};
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

sub ping {
    return 'pong';
}

sub server_time {
    return time;
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

sub website_status {

    return {
        terms_conditions_version => BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version,
        api_call_limits          => site_limits
    };
}

sub check_authorization {
    my $client = shift;

    return create_error({
            code              => 'AuthorizationRequired',
            message_to_client => localize('Please log in.')}) unless $client;

    return create_error({
            code              => 'DisabledClient',
            message_to_client => localize('This account is unavailable.')}) if $client->get_status('disabled');

    my $self_excl = $client->get_self_exclusion;
    my $lim;
    if (    $self_excl
        and $lim = $self_excl->exclude_until
        and Date::Utility->new->is_before(Date::Utility->new($lim)))
    {
        return create_error({
                code              => 'ClientSelfExclusion',
                message_to_client => localize('Sorry, you have excluded yourself until [_1].', $lim)});
    }

    return;
}

sub is_verification_token_valid {
    my ($token, $email) = @_;

    my $session = BOM::Platform::SessionCookie->new({token => $token});
    return unless $session;
    my $response;
    if ($session->email and $session->email eq $email) {
        $response = 1;
    }
    $session->end_session;

    return $response;
}

1;

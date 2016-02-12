package BOM::RPC::v3::Utility;

use strict;
use warnings;

use RateLimitations;
use Date::Utility;

use BOM::Platform::Context qw (localize);
use BOM::Platform::Runtime;
use BOM::Platform::SessionCookie;

sub create_error {
    my $args = shift;
    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{message} ? (message => $args->{message}) : (),
            $args->{details} ? (details => $args->{details}) : ()}};
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

sub is_session_valid {
    my ($token, $email) = @_;
    my $session_cookie = BOM::Platform::SessionCookie->new({token => $token});
    unless ($session_cookie and $session_cookie->email and $session_cookie->email eq $email) {
        return 0;
    }

    return 1;
}

1;

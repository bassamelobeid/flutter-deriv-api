package BOM::RPC::v3::Utility;

use strict;
use warnings;
use RateLimitations;

use BOM::Platform::Context qw (localize);

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
    my @l = RateLimitations::rate_limits_for_service('websocket_call');
    $limits->{'general'} = {
        'applies_to' => 'rest of calls',
        'minutely'   => $l[0]->[1],
        'hourly'     => $l[1]->[1]};
    @l = RateLimitations::rate_limits_for_service('websocket_call_expensive');
    $limits->{'results'} = {
        'applies_to' => 'portfolio, statement and proposal',
        'minutely'   => $l[0]->[1],
        'hourly'     => $l[1]->[1]};
    @l = RateLimitations::rate_limits_for_service('websocket_call_pricing');
    $limits->{'pricing'} = {
        'applies_to' => 'proposal and proposal_open_contract',
        'minutely'   => $l[0]->[1],
        'hourly'     => $l[1]->[1]};
    return $limits;
}

sub website_status {
    my ($app_config) = @_;

    return {
        terms_conditions_version => $app_config->cgi->terms_conditions_version,
        api_call_limits          => site_limits
    };
}

1;

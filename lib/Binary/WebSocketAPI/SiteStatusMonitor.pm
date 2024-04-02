package Binary::WebSocketAPI::SiteStatusMonitor;

=head1 NAME

Binary::WebSocketAPI::SiteStatusMonitor

=head1 DESCRIPTION

This module effectively manages and updates a cached state representing the current site status, ensuring its availability within the memory of the WebSocket worker

The module relays on Redis pub/sub pattern where we send a message to NOTIFY::broadcast::channel when the site status changes,
and we listen to the same channel and update the cached state accordingly.

=cut

use strict;
use warnings;
use Moo;

use Log::Any qw($log);
use JSON::MaybeXS;
use Syntax::Keyword::Try;

use Binary::WebSocketAPI::v3::Instance::Redis 'ws_redis_master';

=head1 ATTRIBUTES

=head2 json

A L<JSON::MaybeXS> object used to encode/decode JSON messages.

=cut

has json => (
    is      => 'ro',
    default => sub { JSON::MaybeXS->new },
);

=head2 redis

 A L<Binary::WebSocketAPI::v3::Instance::Redis> object used to communicate with Redis.

=cut

has redis => (
    is      => 'ro',
    builder => '_build_redis',
);

=head2 site_status

This attribute is used to store the current site status.

=cut

has site_status => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_site_status',
);

=head2 _build_site_status

This sub is used to initialize the site status attribute,
it sets the current site status and subscribes to the NOTIFY::broadcast::channel to update the site status when it changes.

=cut

sub _build_site_status {
    my $self = shift;

    $self->redis->on(
        message => sub {
            my ($redis, $msg, $channel) = @_;
            $self->_update_site_status($msg) if $channel eq 'NOTIFY::broadcast::channel';
        });

    $self->redis->subscribe(["NOTIFY::broadcast::channel"]);

    my $initial_status = $self->redis->get("NOTIFY::broadcast::state");
    return $self->_decode_site_status($initial_status);
}

=head2 _build_redis 

builder method for the redis attribute

=cut

sub _build_redis {
    my $self = shift;
    return ws_redis_master;
}

=head2 _update_site_status

This sub is used to update the site status attribute when the site status changes.

=cut

sub _update_site_status {
    my ($self, $msg) = @_;

    $self->site_status($self->_decode_site_status($msg));
    return;
}

=head2 _decode_site_status

This sub is used to decode redis message to get the site status.

=cut

sub _decode_site_status {
    my ($self, $msg) = @_;

    try {
        $msg = $self->json->decode(Encode::decode_utf8($msg)) if $msg;
    } catch ($e) {
        $log->errorf("Failed to decode site status message: %s", $e);
    };

    # It's safer to assume the site is up if we can't decode the message
    return $msg->{site_status} ? $msg->{site_status} : 'up';
}

1;

package BOM::Test::WebsocketAPI::Redis::Base;

use strict;
use warnings;
no indirect;

use Moo;
use Net::Async::Redis;
use IO::Async::Loop;
use YAML::XS;
use Log::Any qw($log);
use Scalar::Util qw(blessed);

use namespace::clean;

=head1 NAME

BOM::Test::WebsocketAPI::Redis::Base

=head1 DESCRIPTION

The base class for test redis clients. It is an <abstract> class with missing 
B<config> builder implementation.

=head2

=cut

=head2 config

The redis server connection configuration. The builder is delegated to the 'actual' subclasses.

=cut

has 'config' => (is => 'lazy');

=head2 password

The password of the redis connection, read from C<WS_REDIS_PASSWORD> environment variable.

=cut

has 'password' => (is => 'lazy');

sub _build_password {
    return $ENV{WS_REDIS_PASSWORD};
}

=head2 endpoint

The URI of the redis server constructed from the contents of B<config>.

=cut

has 'endpoint' => (is => 'lazy');

sub _build_endpoint {
    my $self   = shift;
    my $config = $self->config;
    return $ENV{WS_REDIS_ENDPOINT} // 'redis://' . $config->{write}->{host} . ':' . $config->{write}->{port};
}

=head2 loop

The IO loop needed for the async redis client.

=cut

has 'loop' => (is => 'lazy');

sub _build_loop {
    return IO::Async::Loop->new();
}

=head2 client

Redis async client, created and connected on demand.

=cut

has 'client' => (is => 'lazy');

sub _build_client {
    my $self = shift;

    my $class    = blessed($self);
    my $endpoint = $self->endpoint;
    $log->infof("$class endpoint is [%s]", $endpoint);

    $self->loop->add(
        my $redis = Net::Async::Redis->new(
            uri => $endpoint,
            (defined($self->password) ? (auth => $self->password) : ()),
        ),
    );

    return $redis->connected->transform(done => sub { $redis });
}

1;

package Binary::WebSocketAPI::v3::Subscription::Feed;

use strict;
use warnings;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::Feed - The class that handle feed channels

=head1 SYNOPSIS

    my $worker = Binary::WebSocketAPI::v3::Subscription::Feed->new(
        c          => $c,
        type       => $type,
        request_storage => $request_storage,
        symbol     => $symbol,
        uuid       => $uuid,
        cache_only => $cache_only || 0,
    );

    $worker->subscribe($callback);  # do subscribe and execute a callback after subscribed.
    $worker->unsubscribe;
    undef $worker; # Destroying the object will also call unsubscribe method

=head1 DESCRIPTION

This module deals with the feed channel subscriptions. We can subscribe one channel
as many times as we want. L<Binary::WebSocketAPI::v3::SubscriptionManager> will
subscribe that channel on redis server only once and this module will register
information that will be fetched when the message arrive. So to avoid duplicate
subscription, we can store the worker in the stash with the unique key.

Please refer to L<Binary::WebSocketAPI::v3::SubscriptionRole>

=cut

use Try::Tiny;
use Scalar::Util qw(looks_like_number);
use List::Util qw(first);
use Log::Any qw($log);
use Moo;
with 'Binary::WebSocketAPI::v3::SubscriptionRole';

use namespace::clean;

=head1 ATTRIBUTES

=head2 cache

used to cache the result

=cut

has cache => (
    is      => 'lazy',
    default => sub { return {} },
    clearer => 1,
);

=head2 symbol

=cut

has symbol => (
    is       => 'ro',
    required => 1,
);

=head2 type

=cut

has type => (
    is       => 'ro',
    required => 1,
);

=head2 cache_only

Sometimes we need only cache, don't want to send a message to the frontend. If so please set it to truth, else false.

=cut

has cache_only => (
    is       => 'rw',
    required => 1,
);

=head2 subscription_manager

Please refer to L<Binary::WebSocketAPI::v3::SubscriptionRole/subscription_manager>

=cut

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->shared_redis_manager();
}

=head2 channel

Please refer to L<Binary::WebSocketAPI::v3::SubscriptionRole/channel>

=cut

sub channel { return 'DISTRIBUTOR_FEED::' . shift->symbol }

=head2 handle_error

Please refer to L<Binary::WebSocketAPI::v3::SubscriptionRole/handle_error>

=cut

sub handle_error {
    my ($self, $err, $message) = @_;
    $log->warnf("error happened in class %s channel %s message %s: $err", $self->class, $self->channel, $message);
    return;
}

=head2 handle_message

Please refer to L<Binary::WebSocketAPI::v3::SubscriptionRole/handle_message>

=cut

sub handle_message {
    my ($self, $payload) = @_;

    my $c = $self->c;

    my $cache = $self->cache;

    my $symbol     = $self->symbol;
    my $type       = $self->type;
    my $arguments  = $self->args;
    my $cache_only = $self->cache_only;
    my $req_id     = $arguments->{req_id};
    return if $payload->{symbol} ne $symbol;
    unless ($c->tx) {
        Binary::WebSocketAPI::v3::Wrapper::Streamer::feed_channel_unsubscribe($c, $symbol, $type, $req_id);
        return;
    }

    my ($msg_type, $result);
    my $epoch = $payload->{epoch};

    if ($type eq 'tick') {
        $msg_type = $type;
        $result   = {
            id     => $self->uuid,
            symbol => $symbol,
            epoch  => 0 + $epoch,
            quote  => $payload->{quote},
            bid    => $payload->{bid},
            ask    => $payload->{ask}};

    } else {
        $msg_type = 'ohlc';
        my ($open, $high, $low, $close) = _parse_ohlc_data_for_type($payload->{ohlc}, $type);
        $result = {
            id        => $self->uuid,
            epoch     => $epoch,
            open_time => ($type and looks_like_number($type))
            ? $epoch - $epoch % $type
            : $epoch - $epoch % 60,    #defining default granularity
            symbol      => $symbol,
            granularity => $type,
            open        => $open,
            high        => $high,
            low         => $low,
            close       => $close,
        };

    }
    if ($cache_only) {
        $cache->{$epoch} = $result;
    } else {
        $c->send({
                json => {
                    msg_type => $msg_type,
                    echo_req => $arguments,
                    (exists $arguments->{req_id})
                    ? (req_id => $arguments->{req_id})
                    : (),
                    $msg_type => $result,
                    subscription => {id => $self->uuid},
                },
            },
            $self->request_storage
        );
    }

    return;
}

sub _parse_ohlc_data_for_type {
    my ($data, $type) = @_;
    my $item = first { m/^$type:/ } split m/;/, $data or die "Couldn't find OHLC data for $type";
    my @fields = $item =~ m/:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+)/ or die "regexp didn't match";
    return @fields;
}

before unsubscribe => sub {
    my $self = shift;
    # as we subscribe to transaction channel for proposal_open_contract so need to forget that also
    Binary::WebSocketAPI::v3::Wrapper::Streamer::transaction_channel($self->c, 'unsubscribe', $self->args->{account_id}, $self->uuid)
        if $self->type =~ /^proposal_open_contract:/;
    return;
};

1;


package Binary::WebSocketAPI::v3::Subscription::Feed;

use strict;
use warnings;
no indirect;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::Feed - The class that handle feed channels

=head1 SYNOPSIS

    my $worker = Binary::WebSocketAPI::v3::Subscription::Feed->new(
        c          => $c,
        type       => $type,
        args       => $args,
        symbol     => $symbol,
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

Please refer to L<Binary::WebSocketAPI::v3::Subscription>

=cut

use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_timing);
use Scalar::Util               qw(looks_like_number);
use List::Util                 qw(first);
use Log::Any                   qw($log);
use Moo;
with 'Binary::WebSocketAPI::v3::Subscription';

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

Please refer to L<Binary::WebSocketAPI::v3::Subscription/subscription_manager>

=cut

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_feed_master_manager();
}

=head2 channel

Please refer to L<Binary::WebSocketAPI::v3::Subscription/channel>

=cut

sub _build_channel { return 'TICK_ENGINE::' . shift->symbol }

=head2 _unique_key

This method is used to find a subscription. Class name + _unique_key will be a
unique index of the subscription objects.

=cut

sub _unique_key {
    my $self = shift;
    my $key  = $self->symbol . ";" . $self->type;
    $key .= ";" . $self->args->{req_id} if $self->args->{req_id};
    return $key;
}

=head2 handle_message

Please refer to L<Binary::WebSocketAPI::v3::Subscription/handle_message>

=cut

sub handle_message {
    my ($self, $payload) = @_;

    my $c = $self->c;

    my $cache = $self->cache;

    my $symbol     = $self->symbol;
    my $type       = $self->type;
    my $arguments  = $self->args;
    my $cache_only = $self->cache_only;
    my $pip_size   = $c->stash->{pip_size}->{$symbol};

    unless ($c->tx) {
        $self->unregister;
        return;
    }

    if (!$pip_size && !$cache_only) {    # Don't proceed if no pip_size and sending to client
        $log->warnf('No pip_size and not being cached  in handle_message ' . __PACKAGE__ . '  unsubscribing and returning');
        $self->unregister;
        return;
    }

    my ($msg_type, $result);
    my $epoch = $payload->{epoch};

    if ($type eq 'tick') {
        $msg_type = $type;
        $result   = {
            id     => "" . $self->uuid,
            symbol => "" . $symbol,
            epoch  => 0 + $epoch,
            quote  => 0 + $payload->{quote},
            bid    => 0 + $payload->{bid},
            ask    => 0 + $payload->{ask},
        };

    } else {
        $msg_type = 'ohlc';
        my ($open, $high, $low, $close) = _parse_ohlc_data_for_type($payload->{ohlc}, $type);
        $result = {
            id        => "" . $self->uuid,
            epoch     => 0 + $epoch,
            open_time => ($type and looks_like_number($type))
            ? $epoch - $epoch % $type
            : $epoch - $epoch % 60,    #defining default granularity
            symbol      => "" . $symbol,
            granularity => 0 + $type,
            open        => "" . $open,
            high        => "" . $high,
            low         => "" . $low,
            close       => "" . $close,
        };

    }
    $result->{pip_size} = 0 + $pip_size;
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
                    $msg_type    => $result,
                    subscription => {id => $self->uuid},
                }});
    }

    my $tv = Time::HiRes::gettimeofday;
    stats_timing('bom_websocket_api.v_3.subscription.feed.send_latency', 1000 * ($tv - $epoch), {tags => ['symbol:' . $symbol]});

    return;
}

sub _parse_ohlc_data_for_type {
    my ($data, $type) = @_;
    my $item   = first { m/^$type:/ } split m/;/, $data or die "Couldn't find OHLC data for $type";
    my @fields = $item =~ m/:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+)/ or die "regexp didn't match";
    return @fields;
}

1;


package Binary::WebSocketAPI::v3::PricingSubscription;

use strict;
use warnings;

use Moo;

use Scalar::Util qw(weaken);
use DataDog::DogStatsd::Helper qw(stats_inc stats_dec);

use Binary::WebSocketAPI::v3::Instance::Redis qw(redis_pricer);

has channel_name => (
    is       => 'ro',
    required => 1
);
has redis_server => (is => 'lazy');

sub BUILD {
    my $self = shift;
    stats_inc('bom_websocket_api.v_3.pricing_subscriptions.instances');

    # For pricer_queue daemon
    my $channel_name = $self->channel_name;
    $self->redis_server->set($channel_name, 1);
    $self->redis_server->subscribe(
        [$channel_name],
        sub {
            my ($redis_self, $err) = @_;
            if ($err) {
                warn "Failed to start pricing subscription for $channel_name due to error: $err";
                stats_inc('bom_websocket_api.v_3.pricing_subscriptions.instances.error');
            } else {
                stats_inc('bom_websocket_api.v_3.pricing_subscriptions.instances.success');
            }
            return $redis_self;
        });
    return $self;
}

sub _build_redis_server {
    return redis_pricer();
}

sub subscribe {
    my ($self, $c) = @_;

    Scalar::Util::weaken($self->redis_server->{shared_info}{$self->channel_name}{$c + 0} = $c);

    stats_inc('bom_websocket_api.v_3.pricing_subscriptions.clients');
    return $self;
}

sub DEMOLISH {
    my $self = shift;

    stats_dec('bom_websocket_api.v_3.pricing_subscriptions.instances');

    my $channel_name = $self->channel_name;
    delete $self->redis_server->{shared_info}{$channel_name};
    $self->redis_server->unsubscribe(
        [$channel_name],
        sub {
            my ($redis_self, $err) = @_;
            if ($err) {
                warn "Failed to stop pricing subscription for $channel_name due to error: $err";
                stats_inc('bom_websocket_api.v_3.pricing_subscriptions.unsubscribe.error');
            } else {
                stats_inc('bom_websocket_api.v_3.pricing_subscriptions.unsubscribe.success');
            }
            return $redis_self;
        });

    return;
}

1;


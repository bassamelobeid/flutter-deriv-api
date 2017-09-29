package Binary::WebSocketAPI::v3::PricingSubscription;

use strict;
use warnings;
use Binary::WebSocketAPI::v3::Instance::Redis qw| redis_pricer |;

use Moo;

use JSON::XS qw| encode_json |;
use Scalar::Util qw| weaken |;
use DataDog::DogStatsd::Helper qw| stats_inc stats_dec |;

has channel_name => (
    is       => 'ro',
    required => 1
);
has redis_server => (is => 'lazy');

sub BUILD {
    my $self = shift;
    stats_inc('bom_websocket_api.v_3.pricing_subscriptions.instances');
    ### For pricer_queue daemon
    $self->redis_server->set($self->channel_name, 1);
    $self->redis_server->publish('first_time_prices', $self->channel_name);
    my $channel_name = $self->channel_name;
    $self->redis_server->subscribe(
        [$self->channel_name],
        sub {
            my ($redis_self, $err) = @_;
            if ($err) {
                warn "Pricing subscription was not started. Channel -->> $channel_name  Error -->> $err";
                stats_inc('bom_websocket_api.v_3.pricing_subscriptions.instances.error');
            } else {
                stats_inc('bom_websocket_api.v_3.pricing_subscriptions.instances.success');
            }
            return $redis_self;
        });
    return $self;
}

sub _build_redis_server {
    return redis_pricer;
}

sub subscribe {
    my ($self, $c) = @_;

    $self->redis_server->{shared_info}{$self->channel_name}{$c + 0} = $c;

    stats_inc('bom_websocket_api.v_3.pricing_subscriptions.clients');

    Scalar::Util::weaken($self->redis_server->{shared_info}{$self->channel_name}{$c + 0});

    return $self;
}

sub DEMOLISH {
    my $self = shift;

    stats_dec('bom_websocket_api.v_3.pricing_subscriptions.instances');

    delete $self->redis_server->{shared_info}{$self->channel_name};
    $self->redis_server->unsubscribe([$self->channel_name]);

    return;
}

1;

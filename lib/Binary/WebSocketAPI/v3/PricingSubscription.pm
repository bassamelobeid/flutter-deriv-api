package Binary::WebSocketAPI::v3::PricingSubscription;

use strict;
use warnings;
use Test::More;
use Data::Dumper;
use Binary::WebSocketAPI::v3::Instance::Redis qw| pricer_write |;

use Moo;

use JSON::XS qw| encode_json         |;
use Scalar::Util qw| weaken              |;
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
    return $self;
}

sub _build_redis_server {
    return pricer_write;
}

sub subscribe {
    my ($self, $c) = @_;

    $self->redis_server->{shared_info}{$self->channel_name}{\$c + 0} = $c;

    stats_inc('bom_websocket_api.v_3.pricing_subscriptions.clients');

    Scalar::Util::weaken($self->redis_server->{shared_info}{$self->channel_name}{\$c + 0});
    $self->redis_server->subscribe([$self->channel_name], sub { });

    return $self;
}

sub DEMOLISH {
    my $self = shift;

    stats_dec('bom_websocket_api.v_3.pricing_subscriptions.instances');

    delete $self->redis_server->{shared_info}{$self->channel_name};
    $self->redis_server->unsubscribe([$self->channel_name]);
    $self->redis_server->del($self->channel_name, 1);
    return;
}

1;

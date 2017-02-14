package Binary::WebSocketAPI::v3::Instance::Subscription;

use strict;
use warnings;
use Moo;
use Data::Dumper;
use Binary::WebSocketAPI::v3::Instance::Redis qw| pricer_write |;
use JSON::XS qw| encode_json |;
use Scalar::Util qw| weaken |;

has channel_name => (
    is       => 'ro',
    required => 1
);
has uuid => (
    is       => 'ro',
    required => 1
);
has redis_server => (is => 'lazy');

sub _build_redis_server {
    return pricer_write;
}

### Now we cannot share subscriptions between clients until move subchannels logic out
sub subscribe {
    my ($self, $c) = @_;

    ### For pricer_queue daemon
    $self->redis_server->set($self->channel_name, 1);

    $self->redis_server->{shared_info}{$self->channel_name}{$self->uuid} = $c;
    Scalar::Util::weaken($self->redis_server->{shared_info}{$self->channel_name}{$self->uuid});
    $self->redis_server->subscribe([$self->channel_name], sub { });

    return $self;
}

sub DEMOLISH {
    my $self = shift;

    $self->redis_server->unsubscribe([$self->channel_name]);
    return;
}

1;

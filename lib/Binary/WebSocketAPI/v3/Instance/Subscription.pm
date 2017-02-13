package Binary::WebSocketAPI::v3::Instance::Subscription;

use strict;
use warnings;
use Data::Dumper;
use Binary::WebSocketAPI::v3::Instance::Redis qw| pricer_write |;
use JSON::XS qw| encode_json |;
use Scalar::Util qw| weaken |;

my ($worker_pid, $instance) = (0, undef);

sub new {
    my $class        = shift;
    my $channel_name = shift;
    my $uuid         = shift;
    my $c            = shift;

    return unless $channel_name;

    my $self = bless {channel_name => $channel_name}, $class;

    pricer_write->set($channel_name, 1);

    pricer_write->{shared_info}{$channel_name}{$uuid} = $c;
    Scalar::Util::weaken(pricer_write->{shared_info}{$channel_name}{$uuid});
    pricer_write->subscribe([$channel_name], sub { });

    return $self;
}

sub DESTROY {
    pricer_write->unsubscribe([shift->{channel_name}]);
    return;
}

1;

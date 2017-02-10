package Binary::WebSocketAPI::v3::Instance::Subscription;

use strict;
use warnings;
use Data::Dumper;
use Binary::WebSocketAPI::v3::Instance::Redis qw| pricer_write |;
use JSON::XS qw| encode_json |;
use Scalar::Util qw| weaken |;
my ( $worker_pid, $instance ) = ( 0, undef );

sub new {
    my $class = shift;
    my $channel_name = shift;
    my $uuid = shift;
    my $c = shift;

    return unless $channel_name;
    warn "NEW SUBSCRIPTION";
    my $self = bless {
                      channel_name => $channel_name
                     }, $class;
    warn "CHANNEL NAME: " . $channel_name;

    pricer_write->set($channel_name, 1);

    pricer_write->{shared_info}{$channel_name}{$uuid} = $c;
    Scalar::Util::weaken(pricer_write->{shared_info}{$channel_name}{$uuid});
    pricer_write->subscribe([$channel_name], sub{warn "Subscribe Created"});

    return $self;
}

sub DESTROY {
    warn "DESTROY";
    pricer_write->unsubscribe([shift->{channel_name}]);
}

1;

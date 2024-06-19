package BOM::Test::WebsocketAPI::Redis::Master;

use strict;
use warnings;
no indirect;
use feature 'state';

use Moo;
use BOM::Test::WebsocketAPI::Redis::Base;
use YAML::XS;

use namespace::clean;

extends 'BOM::Test::WebsocketAPI::Redis::Base';

=head1 NAME

BOM::Test::WebsocketAPI::Redis::Master

=head1 DESCRIPTION

A class repsenting clients to the websocket master redis server (B<ws_redis_master>). It is a subclass of C<BOM::Test::WebsocketAPI::Redis::Base>.

=cut

sub _build_config {
    return YAML::XS::LoadFile('/etc/rmg/ws-redis.yml');
}

1;

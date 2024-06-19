package BOM::Test::WebsocketAPI::Redis::RpcRedis;

use strict;
use warnings;
no indirect;

use Moo;
use BOM::Test::WebsocketAPI::Redis::Base;
use YAML::XS;

use namespace::clean;

extends 'BOM::Test::WebsocketAPI::Redis::Base';

=head1 NAME

BOM::Test::WebsocketAPI::Redis::RpcRedis

=head1 DESCRIPTION

A class representing clients to the RPC Redis server (B<redis_rpc>). It is a subclass of C<BOM::Test::WebsocketAPI::Redis::Base>.

=head2

=cut

sub _build_config {
    return YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_RPC} // '/etc/rmg/redis-rpc.yml');
}

1;

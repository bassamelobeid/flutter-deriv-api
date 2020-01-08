package BOM::Test::WebsocketAPI::Redis::P2P;

use strict;
use warnings;
no indirect;

use Moo;
use BOM::Test::WebsocketAPI::Redis::Base;
use YAML::XS;

use namespace::clean;

extends 'BOM::Test::WebsocketAPI::Redis::Base';

=head1 NAME

BOM::Test::WebsocketAPI::Redis::P2P

=head1 DESCRIPTION

A class repsenting clients to the p2p redis server (B<redis_p2p>). It is a subclass of C<BOM::Test::WebsocketAPI::Redis::Base>.

=head2

=cut

sub _build_config {
    return YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_P2P} // '/etc/rmg/redis-p2p.yml');
}

1;

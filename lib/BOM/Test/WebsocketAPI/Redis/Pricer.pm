package BOM::Test::WebsocketAPI::Redis::Pricer;

use strict;
use warnings;
no indirect;

use Moo;
use BOM::Test::WebsocketAPI::Redis::Base;
use YAML::XS;

use namespace::clean;

extends 'BOM::Test::WebsocketAPI::Redis::Base';

=head1 NAME

BOM::Test::WebsocketAPI::Redis::Pricer

=head1 DESCRIPTION

A class repsenting clients to the pricer redis server (B<redis_pricer>). It is a subclass of C<BOM::Test::WebsocketAPI::Redis::Base>.

=head2

=cut

sub _build_config {
    return YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml');
}

1;

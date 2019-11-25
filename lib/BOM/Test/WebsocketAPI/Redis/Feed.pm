package BOM::Test::WebsocketAPI::Redis::Feed;

use strict;
use warnings;
no indirect;

use Moo;
use BOM::Test::WebsocketAPI::Redis::Base;
use YAML::XS;

use namespace::clean;

extends 'BOM::Test::WebsocketAPI::Redis::Base';

=head1 NAME

BOM::Test::WebsocketAPI::Redis::Feed

=head1 DESCRIPTION

A class repsenting clients to the shared redis server (B<reds_feed_master>). It is a subclass of C<BOM::Test::WebsocketAPI::Redis::Base>.

=head2

=cut

sub _build_config {
    return YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_FEED} // '/etc/rmg/redis-feed.yml');
}

1;

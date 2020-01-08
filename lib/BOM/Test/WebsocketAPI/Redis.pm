package BOM::Test::WebsocketAPI::Redis;

no indirect;

use strict;
use warnings;
use feature 'state';

use BOM::Test::WebsocketAPI::Redis::Feed;
use BOM::Test::WebsocketAPI::Redis::Master;
use BOM::Test::WebsocketAPI::Redis::Pricer;
use BOM::Test::WebsocketAPI::Redis::Transaction;
use BOM::Test::WebsocketAPI::Redis::RpcQueue;
use BOM::Test::WebsocketAPI::Redis::P2P;

=head1 NAME

BOM::Test::WebsocketAPI::Redis

=head1 DESCRIPTION

A factory class for creating C<Future>-based async clients to the test redis server instances.

=head2

=cut

use Exporter qw/import/;
our @EXPORT_OK = qw/redis_feed_master ws_redis_master redis_pricer redis_transaction redis_queue redis_p2p/;

=head2 redis_feed_master

Returns the singleton async client to the test feed redis server (B<redis_feed_master>);

=cut

sub redis_feed_master {
    state $redis = BOM::Test::WebsocketAPI::Redis::Feed->new();

    return $redis->client;
}

=head2 ws_redis_master

Returns the singleton async client to the test websocket master redis server (B<ws_redis_master>).

=cut

sub ws_redis_master {
    state $redis = BOM::Test::WebsocketAPI::Redis::Master->new();

    return $redis->client;
}

=head2 redis_pricer

Returns the singleton async client to the test pricer redis server (B<redis_pricer>);

=cut

sub redis_pricer {
    state $redis = BOM::Test::WebsocketAPI::Redis::Pricer->new();

    return $redis->client;
}

=head2 redis_transaction

Returns the singleton async client to the test transaction redis server (B<redis_transaction>);

=cut

sub redis_transaction {
    state $redis = BOM::Test::WebsocketAPI::Redis::Transaction->new();

    return $redis->client;
}

=head2 redis_p2p

Returns the singleton async client to the test p2p redis server (B<redis_p2p>);

=cut

sub redis_p2p {
    state $redis = BOM::Test::WebsocketAPI::Redis::P2P->new();

    return $redis->client;
}

=head2 redis_queue

Returns the singleton async client to the test rpc queue redis server (B<redis_queue>);

=cut

sub redis_queue {
    state $redis = BOM::Test::WebsocketAPI::Redis::RpcQueue->new();

    return $redis->client;
}

1;

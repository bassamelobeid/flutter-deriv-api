package BOM::Test::WebsocketAPI::Redis;

no indirect;

use strict;
use warnings;
use feature 'state';

use BOM::Test::WebsocketAPI::Redis::Shared;
use BOM::Test::WebsocketAPI::Redis::Master;
use BOM::Test::WebsocketAPI::Redis::Pricer;
use BOM::Test::WebsocketAPI::Redis::Transaction;

=head1 NAME

BOM::Test::WebsocketAPI::Redis

=head1 DESCRIPTION

A factory class for creating C<Future>-based async clients to the test redis server instances.

=head2

=cut

use Exporter qw/import/;
our @EXPORT_OK = qw/shared_redis ws_redis_master redis_pricer redis_transaction/;

=head2 shared_redis

Returns the singleton async client to the test shared redis server (B<shared_redis>);

=cut

sub shared_redis {
    state $redis = BOM::Test::WebsocketAPI::Redis::Shared->new();

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

1;

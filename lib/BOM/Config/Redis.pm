package BOM::Config::Redis;

=head1 NAME

BOM::Config::Redis - Provides read/write pair of redis client

=head1 DESCRIPTION

This module has helper functions to return L<RedisDB> handles, connected
to the appropriate Redis service.

It does not exports these functions by default.

=head1 WARNING

Don't cache returned L<RedisDB> handle for a long term, as all needed
caching is done inside this module.  Better to always call needed
function to get working connection.

=cut

use strict;
use warnings;

use Carp;
use YAML::XS;
use RedisDB;
use Syntax::Keyword::Try;

use BOM::Config;

my $config      = {};
my $connections = {};

# Initialize connection to redis, and store it in hash
# for subsequent requests, if hash has a key, it checks existing connection, and reconnect, if needed.
# Should avoid 'Server unexpectedly closed connection. Some data might have been lost.' error from RedisDB.pm

sub _redis {
    my ($redis_type, $access_type, $timeout) = @_;
    my $key               = join '_', ($redis_type, $access_type, $timeout ? $timeout : ());
    my $connection_config = $config->{$redis_type}->{$access_type};
    if ($access_type eq 'write' && $connections->{$key}) {
        try {
            $connections->{$key}->ping();
        } catch {
            warn "Redis::_redis $key died: $@, reconnecting";
            $connections->{$key} = undef;
        }
    }
    $connections->{$key} //= RedisDB->new(
        $timeout ? (timeout => $timeout) : (),
        host => $connection_config->{host},
        port => $connection_config->{port},
        ($connection_config->{password} ? ('password' => $connection_config->{password}) : ()));

    return $connections->{$key};
}

=head1 FUNCTIONS

=head2 redis_config

    my $redis_rpc_config = BOM::Config::Redis::redis_config(rpc => 'write');

Returns a hashref of C<uri>, C<host>, C<port>, and C<password> (if any)
of the Redis server for a specific type and access level, for supplying
into alternate Redis client handles (if not using the other C<redis_*>
helpers provided by this module.)

Currently supported types are C<queue>, C<replicated>, C<pricer>,
C<exchangerates>, C<feed>, C<events>, C<transaction>, C<auth>, and
C<p2p>.

=cut

sub redis_config {
    my ($redis_type, $access_type) = @_;

    $config->{$redis_type} //= BOM::Config->can("redis_${redis_type}_config")->();

    my $redis = $config->{$redis_type}->{$access_type};

    my $uri = "redis://$redis->{host}:$redis->{port}";

    return {
        uri  => $uri,
        host => $redis->{host},
        port => $redis->{port},
        ($redis->{password} ? ('password' => $redis->{password}) : ())};

}

=head2 redis_replicated_write

    my $redis = BOM::Config::Redis::redis_replicated_write();

Returns a writable L<RedisDB> handle to our standard Redis service with replication enabled.

=cut

sub redis_replicated_write {
    $config->{replicated} //= BOM::Config::redis_replicated_config();
    return _redis('replicated', 'write', 10);
}

=head2 redis_replicated_read

    my $redis = BOM::Config::Redis::redis_replicated_read();

Returns a read-only L<RedisDB> handle to our standard Redis service with replication enabled.

=cut

sub redis_replicated_read {
    $config->{replicated} //= BOM::Config::redis_replicated_config();
    return _redis('replicated', 'read', 10);
}

=head2 redis_write

    my $redis = BOM::Config::Redis::redis_write();

B<Deprecated>.  Returns a writable L<RedisDB> handle to our standard
Redis service with replication enabled.

=cut

sub redis_write {
    carp 'redis_write is DEPRECATED in favor of BOM::Config::Redis::redis_replicated_write';
    return redis_replicated_write();
}

=head2 redis_read

    my $redis = BOM::Config::Redis::redis_read();

B<Deprecated>.  Returns a read-only L<RedisDB> handle to our standard
Redis service with replication enabled.

=cut

sub redis_read {
    carp 'redis_read is DEPRECATED in favor of BOM::Config::Redis::redis_replicated_read';
    return redis_replicated_read();
}

=head2 redis_pricer

    my $redis = BOM::Config::Redis::redis_pricer();

Returns a writable L<RedisDB> handle to our pricer Redis service.

=cut

sub redis_pricer {
    $config->{pricer} //= BOM::Config::redis_pricer_config();
    my %args = @_;
    return _redis('pricer', 'write', $args{timeout} // 10);
}

=head2 redis_pricer_subscription_write

    my $redis = BOM::Config::Redis::redis_pricer_subscription_write();

Returns a writable L<RedisDB> handle to our pricer subscription Redis service.

=cut

sub redis_pricer_subscription_write {
    $config->{pricer_subscription} //= BOM::Config::redis_pricer_subscription_config();
    my %args = @_;
    return _redis('pricer_subscription', 'write', $args{timeout} // 10);
}

=head2 redis_pricer_shared

    my $redis = BOM::Config::Redis::redis_pricer_shared();

Returns a readable L<RedisDB> handle to our shared pricer Redis service.

=head2 redis_pricer_shared_write

    my $redis = BOM::Config::Redis::redis_pricer_shared_write();

Returns a writable L<RedisDB> handle to our shared shared pricer Redis service.

=cut

sub redis_pricer_shared {
    $config->{pricer_shared} //= BOM::Config::redis_pricer_shared_config();
    my %args = @_;
    return _redis('pricer_shared', 'read', $args{timeout} // 10);
}

sub redis_pricer_shared_write {
    $config->{pricer_shared} //= BOM::Config::redis_pricer_shared_config();
    my %args = @_;
    return _redis('pricer_shared', 'write', $args{timeout} // 10);
}

=head2 redis_exchangerates

    my $redis = BOM::Config::Redis::redis_exchangerates();

Returns a read-only L<RedisDB> handle to our ExchangeRates Redis service.

=cut

sub redis_exchangerates {
    $config->{exchangerates} //= BOM::Config::redis_exchangerates_config();
    return _redis('exchangerates', 'read', 10);
}

=head2 redis_exchangerates_write

    my $redis = BOM::Config::Redis::redis_exchangerates_write();

Returns a writable L<RedisDB> handle to our ExchangeRates Redis service.

=cut

sub redis_exchangerates_write {
    $config->{exchangerates} //= BOM::Config::redis_exchangerates_config();
    return _redis('exchangerates', 'write', 10);
}

=head2 redis_feed_master

    my $redis = BOM::Config::Redis::redis_feed_master();

Returns a read-only L<RedisDB> handle to our master feed Redis service.

=cut

sub redis_feed_master {
    $config->{feed} //= BOM::Config::redis_feed_config();
    return _redis('feed', 'master-read');
}

=head2 redis_feed_master_write

    my $redis = BOM::Config::Redis::redis_feed_master_write();

Returns a writable L<RedisDB> handle to our master feed Redis service.

=cut

sub redis_feed_master_write {
    $config->{feed} //= BOM::Config::redis_feed_config();
    return _redis('feed', 'master-write', 10);
}

=head2 redis_feed

    my $redis = BOM::Config::Redis::redis_feed();

Returns a read-only L<RedisDB> handle to our feed Redis service.  Note
that this is different from L<redis_feed_master> in that this handle is
not expected to receive anything when the market is closed.

=cut

sub redis_feed {
    $config->{feed} //= BOM::Config::redis_feed_config();
    # No timeout here as we are expecting not recieving anything when market is closed.
    return _redis('feed', 'read');
}

=head2 redis_feed_write

    my $redis = BOM::Config::Redis::redis_feed_write();

Returns a writable L<RedisDB> handle to our feed Redis service.

=cut

sub redis_feed_write {
    $config->{feed} //= BOM::Config::redis_feed_config();
    return _redis('feed', 'write', 10);
}

=head2 redis_mt5_user_write

    my $redis = BOM::Config::Redis::redis_mt5_user_write();

Returns a writable L<RedisDB> handle to our MT5 user Redis service.

=cut

sub redis_mt5_user_write {
    $config->{mt5_user} //= BOM::Config::redis_mt5_user_config();
    return _redis('mt5_user', 'write', 10);
}

=head2 redis_mt5_user

    my $redis = BOM::Config::Redis::redis_mt5_user();

Returns a read-only L<RedisDB> handle to our MT5 user Redis service.

=cut

sub redis_mt5_user {
    $config->{mt5_user} //= BOM::Config::redis_mt5_user_config();
    return _redis('mt5_user', 'read', 10);
}

=head2 redis_events_write

    my $redis = BOM::Config::Redis::redis_events_write();

Returns a writable L<RedisDB> handle to our bom-events Redis service.

=cut

sub redis_events_write {
    $config->{events} //= BOM::Config::redis_events_config();
    return _redis('events', 'write', 10);
}

=head2 redis_events

    my $redis = BOM::Config::Redis::redis_events();

Returns a read-only L<RedisDB> handle to our bom-events Redis service.

=cut

sub redis_events {
    $config->{events} //= BOM::Config::redis_events_config();
    return _redis('events', 'read', 10);
}

=head2 redis_transaction_write

    my $redis = BOM::Config::Redis::redis_transaction_write();

Returns a writable L<RedisDB> handle to our transaction Redis service.

=cut

sub redis_transaction_write {
    $config->{transaction} //= BOM::Config::redis_transaction_config();
    return _redis('transaction', 'write', 10);
}

=head2 redis_transaction

    my $redis = BOM::Config::Redis::redis_transaction();

Returns a read-only L<RedisDB> handle to our transaction Redis service.

=cut

sub redis_transaction {
    $config->{transaction} //= BOM::Config::redis_transaction_config();
    return _redis('transaction', 'read', 10);
}

=head2 redis_auth_write

    my $redis = BOM::Config::Redis::redis_auth_write();

Returns a writable L<RedisDB> handle to our bom-oauth Redis service.

=cut

sub redis_auth_write {
    $config->{auth} //= BOM::Config::redis_auth_config();
    return _redis('auth', 'write', 10);
}

=head2 redis_auth

    my $redis = BOM::Config::Redis::redis_auth();

Returns a read-only L<RedisDB> handle to our bom-oauth Redis service.

=cut

sub redis_auth {
    $config->{auth} //= BOM::Config::redis_auth_config();
    return _redis('auth', 'read', 10);
}

=head2 redis_expiryq_write

    my $redis = BOM::Config::Redis::redis_expiryq_write();

Returns a writable L<RedisDB> handle to our expiryq Redis service.

=cut

sub redis_expiryq_write {
    $config->{expiryq} //= BOM::Config::redis_expiryq_config();
    return _redis('expiryq', 'write', 10);
}

=head2 redis_expiryq

    my $redis = BOM::Config::Redis::redis_expiryq();

Returns a readable L<RedisDB> handle to our expiryq Redis service.

=cut

sub redis_expiryq {
    $config->{expiryq} //= BOM::Config::redis_expiryq_config();
    return _redis('expiryq', 'read', 10);
}

=head2 redis_p2p_write

    my $redis = BOM::Config::Redis::redis_p2p_write();

Returns a writable L<RedisDB> handle to our P2P Cashier Redis service.

=cut

sub redis_p2p_write {
    $config->{p2p} //= BOM::Config::redis_p2p_config();
    return _redis('p2p', 'write', 10);
}

=head2 redis_p2p

    my $redis = BOM::Config::Redis::redis_p2p();

Returns a read-only L<RedisDB> handle to our P2P Cashier Redis service.

=cut

sub redis_p2p {
    $config->{p2p} //= BOM::Config::redis_p2p_config();
    return _redis('p2p', 'read', 10);
}

=head2 redis_ws_write

    my $redis = BOM::Config::Redis::redis_ws_write();

Returns a writable L<RedisDB> handle to our WS Redis service.

=cut

sub redis_ws_write {
    $config->{ws} //= BOM::Config::redis_ws_config();
    return _redis('ws', 'write', 10);
}

=head2 redis_ws

    my $redis = BOM::Config::Redis::redis_ws();

Returns a read-only L<RedisDB> handle to our WS Redis service.

=cut

sub redis_ws {
    $config->{ws} //= BOM::Config::redis_ws_config();
    return _redis('ws', 'read', 10);
}

=head2 redis_rpc_write

    my $redis = BOM::Config::Redis::redis_rpc_write();

Returns a writable L<RedisDB> handle to our RPC Redis service.
This should be a redis v6 instance.

=cut

sub redis_rpc_write {
    $config->{rpc} //= BOM::Config::redis_rpc_config();
    return _redis('rpc', 'write', 10);
}

=head2 redis_rpc

    my $redis = BOM::Config::Redis::redis_rpc();

Returns a read-only L<RedisDB> handle to our RPC Redis service.
This should be a redis v6 instance.

=cut

sub redis_rpc {
    $config->{rpc} //= BOM::Config::redis_rpc_config();
    return _redis('rpc', 'read', 10);
}

1;

package BOM::Config::RedisReplicated;

=head1 NAME

BOM::Config::RedisReplicated - Provides read/write pair of redis client

=head1 DESCRIPTION

This module has functions to return RedisDB object, connected to appropriate Redis.

Please note:
Don't cache returned object for a long term. All needed caching is done inside
here, so better always call needed function to get working connection.

=cut

use strict;
use warnings;

use YAML::XS;
use RedisDB;
use Try::Tiny;

my $config = {
    replicated    => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-replicated.yml'),
    pricer        => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml'),
    exchangerates => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-exchangerates.yml'),
    feed          => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_FEED}       // '/etc/rmg/redis-feed.yml'),
    mt5_user      => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_MT5_USER}   // '/etc/rmg/redis-mt5user.yml'),
    events        => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_EVENTS}     // '/etc/rmg/redis-events.yml'),
    transaction   => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_TRANSACTION} // '/etc/rmg/redis-transaction.yml'),
    companylimits => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-exchangerates.yml'),
};
my $connections = {};

# Initialize connection to redis, and store it in hash
# for subsequent requests, if hash has a key, it checks existing connection, and reconnect, if needed.
# Should avoid 'Server unexpectedly closed connection. Some data might have been lost.' error from RedisDB.pm

sub _redis {
    my ($redis_type, $access_type, $timeout) = @_;
    my $key = join '_', ($redis_type, $access_type, $timeout ? $timeout : ());
    my $connection_config = $config->{$redis_type}->{$access_type};
    if ($access_type eq 'write' && $connections->{$key}) {
        try {
            $connections->{$key}->ping();
        }
        catch {
            warn "RedisReplicated::_redis $key died: $_, reconnecting";
            $connections->{$key} = undef;
        };
    }
    $connections->{$key} //= RedisDB->new(
        $timeout ? (timeout => $timeout) : (),
        host => $connection_config->{host},
        port => $connection_config->{port},
        ($connection_config->{password} ? ('password' => $connection_config->{password}) : ()));

    return $connections->{$key};
}

sub redis_config {
    my ($redis_type, $access_type) = @_;
    my $redis = $config->{$redis_type}->{$access_type};
    return {
        uri  => "redis://$redis->{host}:$redis->{port}",
        host => $redis->{host},
        port => $redis->{port},
        ($redis->{password} ? ('password' => $redis->{password}) : ())};
}

sub redis_write {
    return _redis('replicated', 'write', 10);
}

sub redis_read {
    return _redis('replicated', 'read', 10);
}

sub redis_pricer {
    my %args = @_;
    return _redis('pricer', 'write', $args{timeout} // 3600);
}

sub redis_exchangerates {
    return _redis('exchangerates', 'read', 10);
}

sub redis_exchangerates_write {
    return _redis('exchangerates', 'write', 10);
}

sub redis_feed_master {
    return _redis('feed', 'master-read');
}

sub redis_feed_master_write {
    return _redis('feed', 'master-write', 10);
}

sub redis_feed {
    # No timeout here as we are expecting not recieving anything when market is closed.
    return _redis('feed', 'read');
}

sub redis_feed_write {
    return _redis('feed', 'write', 10);
}

sub redis_mt5_user_write {
    return _redis('mt5_user', 'write', 10);
}

sub redis_mt5_user {
    return _redis('mt5_user', 'read', 10);
}

sub redis_events_write {
    return _redis('events', 'write', 10);
}

sub redis_events {
    return _redis('events', 'read', 10);
}

sub redis_limits_write {
    return _redis('companylimits', 'write', 10);
}

sub redis_limits {
    return _redis('companylimits', 'read', 10);
}

sub redis_transaction_write {
    return _redis('transaction', 'write', 10);
}

sub redis_transaction {
    return _redis('transaction', 'read', 10);
}

1;

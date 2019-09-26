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

use BOM::Config;

my $config      = {};
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

sub _get_redis_transaction_server {
    my ($landing_company, $timeout) = @_;

    my $connection_config;

    my $key_name;

    # Check if landing company passed in or not
    # If no landing company, default to global settings
    if ($landing_company) {
        $connection_config = $config->{'companylimits'}->{'per_landing_company'}->{$landing_company};
        $key_name          = $landing_company;
    } else {
        $connection_config = $config->{'companylimits'}->{'global_settings'};
        $key_name          = 'global_settings';
    }

    die "connection config should not be undef!" unless $connection_config;

    my $key = 'limit_settings_' . $key_name;

    # TODO: Remove this if-statement in v2
    if ($connections->{$key}) {
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

    $config->{$redis_type} //= BOM::Config->can("redis_${redis_type}_config")->();

    my $redis = $config->{$redis_type}->{$access_type};
    return {
        uri  => "redis://$redis->{host}:$redis->{port}",
        host => $redis->{host},
        port => $redis->{port},
        ($redis->{password} ? ('password' => $redis->{password}) : ())};
}

sub redis_write {
    $config->{replicated} //= BOM::Config::redis_replicated_config();
    return _redis('replicated', 'write', 10);
}

sub redis_read {
    $config->{replicated} //= BOM::Config::redis_replicated_config();
    return _redis('replicated', 'read', 10);
}

sub redis_pricer {
    $config->{pricer} //= BOM::Config::redis_pricer_config();
    my %args = @_;
    return _redis('pricer', 'write', $args{timeout} // 3600);
}

sub redis_exchangerates {
    $config->{exchangerates} //= BOM::Config::redis_exchangerates_config();
    return _redis('exchangerates', 'read', 10);
}

sub redis_exchangerates_write {
    $config->{exchangerates} //= BOM::Config::redis_exchangerates_config();
    return _redis('exchangerates', 'write', 10);
}

sub redis_feed_master {
    $config->{feed} //= BOM::Config::redis_feed_config();
    return _redis('feed', 'master-read');
}

sub redis_feed_master_write {
    $config->{feed} //= BOM::Config::redis_feed_config();
    return _redis('feed', 'master-write', 10);
}

sub redis_feed {
    $config->{feed} //= BOM::Config::redis_feed_config();
    # No timeout here as we are expecting not recieving anything when market is closed.
    return _redis('feed', 'read');
}

sub redis_feed_write {
    $config->{feed} //= BOM::Config::redis_feed_config();
    return _redis('feed', 'write', 10);
}

sub redis_mt5_user_write {
    $config->{mt5_user} //= BOM::Config::redis_mt5_user_config();
    return _redis('mt5_user', 'write', 10);
}

sub redis_mt5_user {
    $config->{mt5_user} //= BOM::Config::redis_mt5_user_config();
    return _redis('mt5_user', 'read', 10);
}

sub redis_events_write {
    $config->{events} //= BOM::Config::redis_events_config();
    return _redis('events', 'write', 10);
}

sub redis_events {
    $config->{events} //= BOM::Config::redis_events_config();
    return _redis('events', 'read', 10);
}

sub redis_limits_write {
    my ($landing_company) = @_;

    $config->{companylimits} //= BOM::Config::redis_limit_settings();
    return _get_redis_transaction_server($landing_company, 10);
}

sub redis_transaction_write {
    $config->{transaction} //= BOM::Config::redis_transaction_config();
    return _redis('transaction', 'write', 10);
}

sub redis_transaction {
    $config->{transaction} //= BOM::Config::redis_transaction_config();
    return _redis('transaction', 'read', 10);
}

sub redis_queue_write {
    $config->{queue} //= BOM::Config::redis_queue_config();
    return _redis('queue', 'write', 10);
}

sub redis_queue {
    $config->{queue} //= BOM::Config::redis_queue_config();
    return _redis('queue', 'read', 10);
}

sub redis_auth_write {
    $config->{auth} //= BOM::Config::redis_auth_config();
    return _redis('auth', 'write', 10);
}

sub redis_auth {
    $config->{auth} //= BOM::Config::redis_auth_config();
    return _redis('auth', 'read', 10);
}
1;

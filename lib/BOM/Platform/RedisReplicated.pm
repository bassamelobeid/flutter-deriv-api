package BOM::Platform::RedisReplicated;

=head1 NAME

BOM::Platform::RedisReplicated - Provides read/write pair of redis client

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
    replicated => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-replicated.yml'),
    pricer     => YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml'),
};
my $connections = {};

# Initialize connection to redis, and store it in hash
# for subsequent requests, if hash has a key, it checks existing connection, and reconnect, if needed.
# Should avoid 'Server unexpectedly closed connection. Some data might have been lost.' error from RedisDB.pm

sub _connect {
    my ($redis_type, $access_type, $timeout) = @_;
    $timeout //= 10;
    my $key = join '_', ($redis_type, $access_type, $timeout);
    my $connection_config = $config->{$redis_type}->{$access_type};
    if ($connections->{$key}) {
        try {
            # I was not able to reproduce an error for the last 24h
            # that's why I'm not sure if separate cases for read and write needed
            # if not - we can keep only ping() regardless of $access_type
            $connections->{$key}->set('test','test') if $access_type eq 'write';
            $connections->{$key}->ping() if $access_type eq 'read'
        }
        catch {
            warn "RedisReplicated::_connect $key died: $_, reconnecting";
            $connections->{$key} = undef;
        };
    }
    $connections->{$key} //= RedisDB->new(
        timeout => $timeout,
        host    => $connection_config->{host},
        port    => $connection_config->{port},
        ($connection_config->{password} ? ('password' => $connection_config->{password}) : ()));

    return $connections->{$key};
}

sub redis_write {
    return _connect('replicated', 'write');
}

sub redis_read {
    return _connect('replicated', 'read');
}

sub redis_pricer {
    return _connect('pricer', 'write', 3600);
}

1;

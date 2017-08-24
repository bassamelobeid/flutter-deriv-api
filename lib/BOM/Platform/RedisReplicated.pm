package BOM::Platform::RedisReplicated;

=head1 NAME

BOM::Platform::RedisReplicated - Provides read/write pair of redis client

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
            $connections->{$key}->ping();
        }
        catch {
            warn "RedisReplicated::_connect existing connection died: $_, reconnecting";
            $connections->{$key} = undef;
        };
    }
    $connections->{$key} //= RedisDB->new(
        timeout => $timeout,
        host    => $connection_config->{host},
        port    => $connection_config->{port},
        ($connection_config->{password} ? ('password', $connection_config->{password}) : ()));

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

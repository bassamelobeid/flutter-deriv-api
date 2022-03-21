package BOM::Config::RedisAsync;

=head1 NAME

BOM::Config::RedisAsync - Provides read/write pair of async redis client

=head1 DESCRIPTION

This module has helper functions to return L<Net::Async::Redis> handles, connected
to the appropriate Redis service.

It does not exports these functions by default.

=head2 _redis
=head1 WARNING

Don't cache returned L<Net::Async::Redis> handle for a long term, as all needed
caching is done inside this module.  Better to always call needed
function to get working connection.

=cut

use strict;
use warnings;

use Carp;
use YAML::XS;
use Syntax::Keyword::Try;

use BOM::Config;
use Net::Async::Redis;
use Future::AsyncAwait;

my $config      = {};
my $connections = {};

# Initialize connection to redis, and store it in hash
# for subsequent requests, if hash has a key, it checks existing connection, and reconnect, if needed.

async sub _redis {
    my ($redis_type, $access_type) = @_;
    my $key               = join '_', ($redis_type, $access_type);
    my $connection_config = $config->{$redis_type}->{$access_type};
    if ($access_type eq 'write' && $connections->{$key}) {
        try {
            await $connections->{$key}->ping();
        } catch ($e) {
            warn "Redis::_redis $key died: $e, reconnecting";
            $connections->{$key} = undef;
        }
    }
    $connections->{$key} //= Net::Async::Redis->new(
        uri  => "redis://$connection_config->{host}:$connection_config->{port}",
        auth => $connection_config->{password});

    return $connections->{$key};
}

=head2 redis_replicated_write_async

    my $redis = BOM::Config::RedisAsync::redis_replicated_write_async();

Returns a writable L<Net::Async::Redis> handle to our standard Redis service with replication enabled.

=cut

async sub redis_replicated_write_async {
    $config->{replicated} //= BOM::Config::redis_replicated_config();
    return await _redis('replicated', 'write');
}

1;

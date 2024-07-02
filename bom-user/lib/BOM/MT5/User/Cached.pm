package BOM::MT5::User::Cached;

use strict;
use warnings;
use feature 'state';

use JSON::MaybeXS;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::MT5::User::Async;
use Future::AsyncAwait;
use RedisDB;
use Syntax::Keyword::Try;
use Log::Any qw($log);
use constant {
    CACHE_EXPIRATION_SECONDS => 300,
};

sub _initiate_new_redis_instance {
    my $redis_cfds_config = BOM::Config::redis_cfds_config();
    my $redis_instance    = RedisDB->new(
        host               => $redis_cfds_config->{write}{host},
        port               => $redis_cfds_config->{write}{port},
        password           => $redis_cfds_config->{write}{password},
        reconnect_attempts => 0,
    );
    return $redis_instance;
}

sub _get_redis_instance {
    state $redis_instance;
    return $redis_instance if ($redis_instance and $redis_instance->ping);

    $log->info("Creating new Redis instance for MT5 API cache");
    $redis_instance = _initiate_new_redis_instance();
    return $redis_instance;
}

sub _set_cache {
    my ($key, $value, $expiration) = @_;
    try {
        _get_redis_instance->set($key, encode_json($value), 'EX', $expiration // CACHE_EXPIRATION_SECONDS);
    } catch {
        $log->warn("Failed to set MT5 API cache");
    };
}

sub _get_cache {
    my ($key) = @_;
    my $json_str = _get_redis_instance->get($key);
    return decode_json($json_str) if $json_str;
    return;
}

sub invalidate_mt5_api_cache {
    my ($mt5_loginid) = @_;
    try {
        _get_redis_instance->del("get_user:$mt5_loginid");
    } catch {
        $log->warn("Failed to delete MT5 API cache");
    };
}

async sub get_user_cached {
    my ($mt5_loginid) = @_;
    my $cache_key = "get_user:$mt5_loginid";

    try {
        my $cached_user = _get_cache($cache_key);
        return $cached_user if $cached_user;
    } catch {
        $log->warn("Failed to get MT5 API cache");
    }

    my $user = await BOM::MT5::User::Async::get_user($mt5_loginid);
    return $user if ($user->{error} || $user->{code});

    $user->{request_timestamp} = time;
    _set_cache($cache_key, $user, BOM::Config::Runtime->instance->app_config->system->mt5->mt5_cache_expiry);
    return $user;
}

1;

__END__

=head1 NAME

BOM::MT5::User::Cached - Caching layer for User::Async module using Redis

=head1 SYNOPSIS

  use BOM::MT5::User::Cached qw(get_user_cached);

  my $user = get_user_cached($mt5_loginid);
  print "User: ", $user->{group}, "\n";

=head1 DESCRIPTION

This module provides a caching layer for the User::Async module, using Redis
for caching responses. It ensures that repeated API calls for the same data
are served from the cache, improving performance and reducing load on the API.

=cut 

=head2 get_user_cached

  my $user = get_user_cached($mt5_loginid);

Returns a Future with user data for the given loginid, checking the cache first and
falling back to the original API call if the data is not found in the cache.

=head2 invalidate_mt5_api_cache

  invalidate_mt5_api_cache($loginid);

Invalidates the cache for the given loginid, causing the next call to fetch the data from the API.
The Redis key consists of API call name and parameters separated by colons. For example, get_user:MTR12345.

=head2 _initiate_new_redis_instance

=head2 _get_redis_instance

=head2 _set_cache

=head2 _get_cache

Internal helper functions for managing the Redis cache.

=cut

package BOM::Config::RedisTransactionLimits;

=head1 NAME

BOM::Config::RedisTransactionLimits

=head1 DESCRIPTION

Returns a RedisDB instance given a landing company object. If no parameter is
given, the global settings redis instance is returned. We implemented it this
way to allow sharding for different landing companies via a configuration tweak
in /etc/rmg/redis-transaction-limits.yml in Chef. Because of this, the configuration
yml structure is different from other Redis yml config files.

In QA environment it is all pointed to the same local Redis server at port 6329.

Please note:
Don't cache returned object for a long term. All needed caching is done inside
here, so better always call needed function to get working connection.

=cut

use strict;
use warnings;

use RedisDB;
use Try::Tiny;

use BOM::Config;

my $config      = {};
my $connections = {};

sub _get_redis_transaction_server {
    my ($landing_company, $timeout) = @_;

    my $connection_config;

    my $key_name;

    # Check if landing company passed in or not
    # If no landing company, default to global settings
    if ($landing_company) {
        $key_name          = $landing_company->short;
        $connection_config = $config->{'companylimits'}->{'per_landing_company'}->{$key_name};
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

sub redis_limits_write {
    my ($landing_company) = @_;

    $config->{companylimits} //= BOM::Config::redis_limit_settings();
    return _get_redis_transaction_server($landing_company, 10);
}

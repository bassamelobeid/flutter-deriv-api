package BOM::Config::TransactionLimits;

=head1 NAME

BOM::Config::TransactionLimits - Provides write access of redis transaction, based on landing company

=head1 DESCRIPTION

This module has function to return RedisDB object, connected to appropriate Redis.

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
        $connection_config = $config->{'companylimits'}->{'per_landing_company'}->{$landing_company->short};
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

sub redis_limits_write {
    my ($landing_company) = @_;

    $config->{companylimits} //= BOM::Config::redis_limit_settings();
    return _get_redis_transaction_server($landing_company, 10);
}

package BOM::Plarform::RedisReplicated;

=head1 NAME

BOM::Plarform::RedisReplicated - Provides read/write pair of redis client

=cut

use strict;
use warnings;
use feature "state";    # We use singletons for read and write redis instances

use YAML::XS;
use RedisDB;

sub redis_write {
    state $redis_write = do {
        my $config = _config();
        RedisDB->new(
            timeout => 10,
            host    => $config->{write}->{host},
            port    => $config->{write}->{port},
            ($config->{write}->{password} ? ('password', $config->{write}->{password}) : ()));
    };
    return $redis_write;
}

sub redis_read {
    state $redis_read = do {
        my $config = _config();
        RedisDB->new(
            timeout => 10,
            host    => $config->{read}->{host},
            port    => $config->{read}->{port},
            ($config->{read}->{password} ? ('password', $config->{read}->{password}) : ()));
    };
    return $redis_read;
}

state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-replicated.yml');

sub _config {
    return $config;
}

sub redis_pricer {
    state $redis_pricer = do {
        my $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml');
        RedisDB->new(
            timeout => 3600,
            host    => $config->{write}->{host},
            port    => $config->{write}->{port},
            ($config->{write}->{password} ? ('password', $config->{write}->{password}) : ()));
    };
    return $redis_pricer;
}

1;

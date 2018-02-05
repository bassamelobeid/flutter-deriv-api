package BOM::Platform::Config;

use strict;
use warnings;

use feature "state";
use YAML::XS;

sub node {
    state $config = YAML::XS::LoadFile('/etc/rmg/node.yml');
    return $config;
}

sub role {
    return (any { $_ eq shift } @{BOM::Platform::Config::node()->{node}->{roles}});
}

sub feed_listener {
    state $config = YAML::XS::LoadFile('/etc/rmg/feed_listener.yml');
    return $config;
}

sub aes_keys {
    state $config = YAML::XS::LoadFile('/etc/rmg/aes_keys.yml');
    return $config;
}

sub randsrv {
    state $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_RAND} // '/etc/rmg/randsrv.yml');
    return $config;
}

sub third_party {
    state $config = YAML::XS::LoadFile('/etc/rmg/third_party.yml');
    return $config;
}

sub quants {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-platform/config/quants_config.yml');
    return $config;
}

sub payment_agent {
    state $config = YAML::XS::LoadFile('/home/git/regentmarkets/bom-platform/config/paymentagent_config.yml');
    return $config;
}

sub sanction_file {
    return "/var/lib/binary/sanctions.yml";
}

{
    my $env = do {
        local @ARGV = ('/etc/rmg/environment');
        readline;
    };
    chomp $env;

    sub env {
        return $env;
    }
}

sub on_production {
    return env() eq 'production';
}

sub on_qa {
    return env() =~ /^qa/;
}

1;

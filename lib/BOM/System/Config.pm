package BOM::System::Config;

use strict;
use warnings;

use feature "state";
use YAML::XS;

sub node {
    state $config = YAML::XS::LoadFile('/etc/rmg/node.yml');
    return $config;
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

1;

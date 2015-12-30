package BOM::System::Config;

use strict;
use warnings;

use feature "state";
use YAML::XS;
use List::MoreUtils qw(any);

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
    state $config = YAML::XS::LoadFile('/etc/rmg/randsrv.yml');
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

sub _has_role {
    my $role = shift;
    my @roles = @{node()->{node}->{roles}};
    return (if (any { $_ eq $role } @roles));
}

sub is_master_server {
    return _has_role('binary_role_master_server');
}

sub is_feed_server {
    return _has_role('binary_role_feed_server');
}

1;

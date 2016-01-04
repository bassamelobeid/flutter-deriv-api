package BOM::System::Localhost;

use strict;
use warnings;

use BOM::System::Config;
use List::MoreUtils qw(any);
use Sys::Hostname qw();

sub _has_role {
    my $role  = shift;
    my @roles = @{BOM::System::Config::node()->{node}->{roles}};
    return (any { $_ eq $role } @roles);
}

sub is_master_server {
    return _has_role('binary_role_master_server');
}

sub is_feed_server {
    return _has_role('binary_role_feed_server');
}

sub fqdn {
    return Sys::Hostname::hostname;
}

sub external_fqdn {
    return name() . '.' . external_domain();
}

sub name {
    my @host_name = split(/\./, Sys::Hostname::hostname);
    return $host_name[0];
}

sub domain {
    return 'regentmarkets.com';
}

sub external_domain {
    my $env = BOM::System::Config::env;
    if ($env =~ /^qa/) {
        return 'binary' . $env . '.com';
    }
    return 'binary.com';
}

1;

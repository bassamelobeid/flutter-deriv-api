package BOM::System::Localhost;

use strict;
use warnings;

use BOM::System::Config;
use List::MoreUtils qw(any);
use Sys::Hostname qw();

sub _has_role {
    my $role = shift;
    my @roles = @{BOM::System::Config::node()->{node}->{roles}};
    return (if (any { $_ eq $role } @roles));
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

1;

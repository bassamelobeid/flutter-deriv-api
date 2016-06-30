package BOM::System::Localhost;

use strict;
use warnings;

use BOM::System::Config;
use List::MoreUtils qw(any);
use Sys::Hostname qw();

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
    my $name = name();
    if ($name =~ /^qa\d+$/) {
        return 'binary' . $name . '.com';
    }
    return 'binary.com';
}

1;

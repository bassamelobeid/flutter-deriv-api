package BOM::RPC::JobTimeout;

=head1 NAME

BOM::RPC::JobTimeout - Package for stuff related to RPC Job timeout

=head1 DESCRIPTION

This package handles all the config related to job timeout.

=cut

use strict;
use warnings;

use YAML::XS;

my $config = {};

sub _get_config {
    $config = keys %$config ? $config : YAML::XS::LoadFile($ENV{RPC_JOB_TIMEOUT} // '/etc/rmg/rpc_queue_timeout.yml');
    return $config;
}

=head2 get_timeout

This sub returns the timeout for each category of rpc call.
Defaults to 'default' if not provided.

=cut

sub get_timeout {
    my %args = @_;

    my $category = $args{category} // 'default';

    return _get_config()->{$category}->{timeout};
}

1;

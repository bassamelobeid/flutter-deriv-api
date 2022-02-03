package BOM::Config::Services;

=head1 NAME

BOM::Config::Services

=head1 DESCRIPTION

Class for managing configuration for internal services.

=cut

use strict;
use warnings;
use feature 'state';
no indirect;

use Syntax::Keyword::Try;
use Carp;

use BOM::Config;
use BOM::Config::Runtime;

=head2 is_enabled

Predicat to check status of the service

    BOM::Config::Services->is_enabled('service1');

=cut

sub is_enabled {
    my ($class, $service) = @_;

    croak 'Service name is missed' unless $service;

    my $service_cfg = $class->config($service);

    croak "Invalid service name $service" unless $service_cfg;

    return 0 unless $service_cfg->{enabled};

    my $app_cfg = BOM::Config::Runtime->instance->app_config;
    $app_cfg->check_for_update;

    try {
        return $app_cfg->system->services->$service()
    } catch {
        die "Dynamic configuration for $service is missed";
    }
}

=head2 config

Returns configuration for the service

    BOM::Config::Services->config('service1');

=cut

sub config {
    my ($class, $service) = @_;

    croak 'Service name is missed' unless $service;

    my $service_cfg = BOM::Config->services_config->{$service};

    croak "Invalid service name $service" unless $service_cfg;

    return $service_cfg;
}

1;

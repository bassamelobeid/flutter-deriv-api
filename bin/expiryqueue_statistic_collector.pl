#!/usr/bin/env perl

package BOM::System::Script::ExpiryQueueStatisticCollector;

=head1 NAME

BOM::System::Script::ExpiryQueueStatisticCollector

=head1 DESCRIPTION

Expose statistics for the status of the expiry queue.

=cut

use Moose;

use BOM::Platform::Runtime;
with 'App::Base::Script';
with 'BOM::Utility::Logging';
use BOM::System::Config;

use DataDog::DogStatsd::Helper qw(stats_gauge);
use ExpiryQueue qw( queue_status );

sub script_run {
    my $self = shift;

    my $tags = {tags => ['rmgenv:' . BOM::System::Config::env,]};
    my $status = queue_status();
    foreach my $which (keys %$status) {
        stats_gauge('expiryqueue.' . $which, $status->{$which}, $tags);
    }

    return 0;
}

sub documentation { return qq{ The script gathers and reports information about expiry queue status }; }

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package main;
use strict;

exit BOM::System::Script::ExpiryQueueStatisticCollector->new->run;

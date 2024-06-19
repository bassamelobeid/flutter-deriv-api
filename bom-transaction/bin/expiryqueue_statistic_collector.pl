#!/etc/rmg/bin/perl

package BOM::Transaction::ExpiryQueueStatisticCollector;

=head1 NAME

BOM::Transaction::ExpiryQueueStatisticCollector

=head1 DESCRIPTION

Expose statistics for the status of the expiry queue.

=cut

use Moose;

use BOM::Config::Runtime;
with 'App::Base::Script';
use BOM::Config;
use BOM::Config::Redis;

use DataDog::DogStatsd::Helper qw(stats_gauge);
use ExpiryQueue;

sub script_run {
    my $self = shift;

    my $tags    = {tags => ['rmgenv:' . BOM::Config::env,]};
    my $expiryq = ExpiryQueue->new(redis => BOM::Config::Redis::redis_expiryq_write);
    my $status  = $expiryq->queue_status();
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

exit BOM::Transaction::ExpiryQueueStatisticCollector->new->run;

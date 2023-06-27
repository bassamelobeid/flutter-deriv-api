package BOM::FeedPlugin::Plugin::ExpiryQueue;

use strict;
use warnings;

use Moo;
use BOM::Config::Redis;
use ExpiryQueue;
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);

=head1 NAME

BOM::FeedPlugin::Plugin::ExpiryQueue

=head1 SYNOPSIS

use BOM::FeedPlugin::Plugin::ExpiryQueue

=head1 DESCRIPTION

This package is used as a plugin by L<BOM::FeedPlugin::Client> where it will be called if it was added to the array of plugins in Client.
Its used to update Expiry Queue for tick by invoking L<ExpiryQueue>.

=cut

has expiryq => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_expiryq',
);

sub _build_expiryq {
    my $redis = BOM::Config::Redis::redis_expiryq_write();
    return ExpiryQueue->new(redis => $redis);
}

=head2 $self->on_tick($tick)

The main method which it will receive a tick and then invoke I<update_queue_for_tick> with the latest tick, and update DD stats.

=cut

sub on_tick {
    my ($self, $tick) = @_;

    # At this moment, this tick should be available to the clients that are using it.
    # Log the latency here.
    my $ts = Time::HiRes::time;

    $self->expiryq->update_queue_for_tick($tick);
    # update statistics about number of processed ticks (once in 10 ticks)

    my $basename = 'feed.client.plugin.expiry_queue';
    my $latency  = $ts - $tick->{epoch};
    my $tags     = {tags => ['seconds:' . int($latency)]};

    stats_timing("$basename.latency", 1000 * $latency, $tags);

    return;
}

1;

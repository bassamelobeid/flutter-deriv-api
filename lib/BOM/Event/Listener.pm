package BOM::Event::Listener;

use strict;
use warnings;

use Date::Utility;
use BOM::Platform::Event::Emitter;
use BOM::Event::Process;
use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);

use constant QUEUE_WAIT_DURATION => 1;

=head1 NAME

BOM::Event::Listener - Listen to events

=head1 SYNOPSIS

    BOM::Event::Listener::run()

=head1 DESCRIPTION

This class runs periodically and get emitted event and pass that to
Event::Process to process fetched event.

=cut

=head2 run

Process the task sequentially for fixed amount of time.

=head3 Required parameters

=over 4

=item * name of the queue

=back

=cut

sub run {
    my ($self, $queue_name) = @_;

    my $loop = IO::Async::Loop->new;
    while (1) {
        run_once($queue_name);
        $loop->delay_future(after => QUEUE_WAIT_DURATION)->get;
    }

    return;
}

=head2 run_once

Process the element of the queue once

=head3 Required parameters

=over 4

=item * name of the queue

=back

=cut

sub run_once {
    my $queue_name = shift;

    my $event_to_be_processed = BOM::Platform::Event::Emitter::get($queue_name);

    return undef unless $event_to_be_processed;
    BOM::Event::Process::process($event_to_be_processed, $queue_name);

    return undef;
}

1;

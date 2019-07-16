package BOM::Event::QueueHandler;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

=head1 NAME

BOM::Event::QueueHandler

=head1 DESCRIPTION

=cut

no indirect;
use mro;
use Syntax::Keyword::Try;
use Scalar::Util qw(blessed);
use Future::Utils qw(repeat);
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use BOM::Event::Services;
use BOM::Event::Process;
use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use Log::Any qw($log);

=head2 DEFAULT_QUEUE_WAIT_TIME

How long (in seconds) to wait for an event on each iteration.

=cut

use constant DEFAULT_QUEUE_WAIT_TIME => 10;

=head2 MAXIMUM_PROCESSING_TIME

How long (in seconds) to allow for the process
call to wait for L</process_event>.

=cut

use constant MAXIMUM_PROCESSING_TIME => 30;

=head2 MAXIMUM_JOB_TIME

How long (in seconds) to allow for a single async call is allowed.

=cut

use constant MAXIMUM_JOB_TIME => 10;

=head2 configure

Called from the constructor and can also be used manually to update
values.

Takes the following named parameters:

=over 4

=item * C<queue> - the queue name to monitor

=item * C<queue_wait_time> - how long (in seconds) to wait for events

=item * C<maximum_job_time> - total amount of a time a single async job is
allowed to take. Note that this is separate from L</MAXIMUM_PROCESSING_TIME>.
=back

=cut

sub configure {
    my ($self, %args) = @_;
    for (qw(queue queue_wait_time maximum_job_time)) {
        $self->{$_} = delete $args{$_} if exists $args{$_};
    }
    return $self->next::method(%args);
}

=head2 redis

The L<BOM::Event::Services> instance.

=cut

sub services {
    my ($self) = @_;
    return $self->{services} //= do {
        $self->add_child(my $services = BOM::Event::Services->new);
        $services;
        }
}

=head2 redis

The L<Net::Async::Redis> instance.

=cut

sub redis {
    my ($self) = @_;
    return $self->{redis} //= $self->services->redis_events_write();
}

=head2 _add_to_loop

Called when this instance is added to an L<IO::Async::Loop>.

This will connect to the Redis server and start the job handling.

=cut

sub _add_to_loop {
    my ($self, $loop) = @_;
    # Initiate connection and processing as soon as we're added to the loop
    return $self->redis->connect->then($self->curry::weak::process_loop)->retain;
}

=head2 queue_name

Returns the queue name which contains the events;

=cut

sub queue_name { return shift->{queue} }

=head2 queue_wait_time

Returns the current timeout while waiting for a message from redis

We should not cache this value as it could be changed in run-time

Note that the processing will be blocked until new data comes hence we 
need a timeout.

=cut

sub queue_wait_time { return (shift->{queue_wait_time} || DEFAULT_QUEUE_WAIT_TIME) }

=head2 maximum_job_time

Returns the maximum timeout configured per an async job

We should not cache this value as it could be changed in run-time

=cut

sub maximum_job_time { return (shift->{maximum_job_time} || MAXIMUM_JOB_TIME) }

=head2 should_shutdown

Returns a L<Future> which can be marked as L<Future/done> to halt any further queue
processing.

=cut

sub should_shutdown {
    my ($self) = @_;
    return $self->{should_shutdown} //= $self->loop->new_future->set_label('QueueHandler::shutdown');
}

=head2 process_loop

Returns the L<Future> representing the processing loop, starting it if required.

This is the main logic for waiting on events from the Redis queue and calling the
appropriate handler.

=cut

sub process_loop {
    my ($self) = @_;
    return $self->{process_loop} //= (
        repeat {
            Future->wait_any(
                # This resolves as done, but we want to bail out of the loop,
                # and we do that by returning a failed future from the repeat block
                $self->should_shutdown->without_cancel->then_fail('normal_shutdown'),
                $self->redis->brpop(
                    # We don't cache these: each iteration uses the latest values,
                    # allowing ->configure to change name and wait time dynamically.
                    $self->queue_name,
                    $self->queue_wait_time
                    )->then(
                    sub {
                        my ($item) = @_;
                        # $item will be undef in case of timeout occurred
                        return Future->done() unless $item;

                        my ($queue_name, $event_data) = $item->@*;

                        unless ($event_data) {
                            $log->errorf('Invalid event data received');
                            # Stop our processing, this indicates something is not
                            # right and needs further investigation
                            return Future->fail('bad event data - nothing received');
                        }

                        try {
                            my $decoded_data = decode_json_utf8($event_data);
                            stats_inc(lc "$queue_name.read");
                            return Future->done($queue_name => $decoded_data);
                        }
                        catch {
                            my $err = $@;
                            stats_inc(lc "$queue_name.invalid_data");
                            # Invalid data indicates serious problems, we halt
                            # entirely and record the details
                            $log->errorf('Bad data received in event queue %s causing exception %s - data was %s', $queue_name, $err, $event_data);
                            return Future->fail("bad event data - $err");
                        }
                    }
                    )->then(
                    sub {
                        # redis message will be undef in case of timeout occurred
                        return Future->done() unless @_;
                        my ($queue_name, $event_data) = @_;

                        try {
                            # A local setting for this is fine here: we are limiting the initial call,
                            # not the time spent in any subsequent context switches due to async/await.
                            local $SIG{ALRM} = sub {
                                die "alarm\n";
                            };
                            alarm(MAXIMUM_PROCESSING_TIME);

                            # A handler might be a sync sub or an async sub
                            # Future->wrap will return immediately if it has a scalar

                            my $f = Future->wrap(BOM::Event::Process::process($event_data, $queue_name));
                            return Future->wait_any($f, $self->loop->timeout_future(after => $self->maximum_job_time))->on_fail(
                                sub {
                                    $log->errorf("Event from queue %s failed or did not complete within %s sec - data was %s",
                                        $queue_name, $self->maximum_job_time, $event_data);
                                    stats_inc(lc "$queue_name.processed.failure");
                                })->else_done();
                        }
                        catch {
                            $log->errorf('Failed to process %s (data %s) - %s', $queue_name, $event_data, $@);
                            # This one's less clear cut than other failure cases:
                            # we *do* expect occasional failures from processing,
                            # and normally that does not imply everything is broken.
                            # However, continuous failures should perhaps be treated
                            # more seriously?
                            return Future->done;
                        }
                        finally {
                            alarm(0);
                        }
                    }))
        }
        while => sub {
            # We keep going until something fails
            shift->is_done;
        }
        )->on_ready(
        sub {
            # ... and allow restart if we're stopped or fail,
            # next caller to this method will start things up again
            delete $self->{process_loop} if $self->{process_loop};
        });
}

1;


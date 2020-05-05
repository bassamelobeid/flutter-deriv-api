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
use BOM::Event::Utility qw(exception_logged);

=head2 DEFAULT_QUEUE_WAIT_TIME

How long (in seconds) to wait for an event on each iteration.

=cut

use constant DEFAULT_QUEUE_WAIT_TIME => 10;

=head2 MAXIMUM_PROCESSING_TIME

How long (in seconds) to allow for the process
call to wait for L</process_event>.
Note: MAXIMUM_JOB_TIME can be greater than this if the job is 
Async. 

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

=item * C<maximum_processing_time> - maximum amount of time a job can be 
initiated for.  It basically means how long can it spend  in the actual end
event subroutine. So if the end subroutine is async  this can be shorter
than the L<MAXIMUM_JOB_TIME>  .

=back

=cut

sub configure {
    my ($self, %args) = @_;
    for (qw(queue queue_wait_time maximum_job_time maximum_processing_time)) {
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
    my ($self) = @_;
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

=head2 maximum_processing_time

Returns the maximum timeout configured for the processing of a job.


=cut

sub maximum_processing_time { return (shift->{maximum_processing_time} || MAXIMUM_PROCESSING_TIME) }

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
                            $log->errorf('Bad data received in event queue %s causing exception %s - data was %s',
                                $queue_name, $err, $self->clean_data_for_logging($event_data));
                            exception_logged();
                            return Future->fail("bad event data - $err");
                        }
                    }
                    )->then(
                    sub {
                        # redis message will be undef in case of timeout occurred
                        return Future->done() unless @_;
                        my ($queue_name, $event_data) = @_;
                        $self->process_job($queue_name, $event_data);

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

=head2 process_job

Description: Handles the timeouts and launching the processing of the actual jobs. Not in-lined so that it can be more easily tested. 
Takes the following arguments 

=over 4

=item - $queue_name : The name of the redis queue the job is from 

=item - $event_data : The Data that was passed to the event. 

=back

Returns a L<FUTURE>

=cut

sub process_job {
    my ($self, $queue_name, $event_data) = @_;
    try {
        # A local setting for this is fine here: we are limiting the initial call,
        # not the time spent in any subsequent context switches due to async/await.
        local $SIG{ALRM} = sub {
            die "Max_Processing_Time Reached\n";
        };
        alarm($self->maximum_processing_time);

        # A handler might be a sync sub or an async sub
        # Future->wrap will return immediately if it has a scalar
        # Due to Perl stack refcounting issues, we occasionally see exceptions here with
        # a message like "Can't call method "wrap" without a package or object reference"
        # - storing in an intermediary variable here to keep the result alive long enough
        # for Future->wrap to work. Note that the actual stack element which Perl complains about
        # is just the class name (the string 'Future') - this would likely need some quality time with gdb
        # to dissect fully.
        my $res = BOM::Event::Process::process($event_data, $queue_name);
        my $f = Future->wrap($res);
        return Future->wait_any($f, $self->loop->timeout_future(after => $self->maximum_job_time))->on_fail(
            sub {
                my $cleaned_data = $self->clean_data_for_logging($event_data);
                if (defined $f->failure and $f->failure =~ /Max_Processing_Time/) {

                    # This can happen when a job being run is not
                    # asynchronous, it takes longer than MAX_PROCESSING_TIME and the sub has the async label.
                    $log->errorf(
                        "Processing of request  from queue %s took longer than 'MAXIMUM_PROCESSING_TIME' %s seconds - data was %s",
                        $queue_name, $self->maximum_processing_time,
                        $cleaned_data
                    );
                } elsif (defined $f->failure) {
                    $log->errorf("Event from queue %s failed  data was %s error was : %s", $queue_name, $cleaned_data, $f->failure);
                } else {
                    $log->errorf("Event from queue %s did not complete within %s sec - data was %s ",
                        $queue_name, $self->maximum_job_time, $cleaned_data, $f->failure);
                }
                stats_inc(lc "$queue_name.processed.failure");
            })->else_done();
    }
    catch {
        $log->errorf('Failed to process %s (data %s) - %s', $queue_name, $self->cleaned_data($event_data), $@);
        exception_logged();
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
}

=head2 clean_data_for_logging

Description: Cleans out any data that might be GDPR sensitive when the log level is not debug. 

Takes the following arguments

=over 4

=item - event_data - The JSON string obtained from Redis for the job details.  


=back

Returns a JSON string with sanitized event data 

=cut

sub clean_data_for_logging {
    my ($self, $event_data) = @_;
    # Event Data looks like {"details":{"loginid":"CR2000000"},"context":{"language":"EN","brand_name":"binary"},"type":"api_token_deleted"}
    # where "details" is the values passed with the event and "type" is the name of the event.
    if ($log->is_debug()) {
        return $event_data;
    }
    my $decoded_data;
    try {
        $decoded_data = decode_json_utf8($event_data);
    }
    catch {
        exception_logged();
        return "Invalid JSON format event data";
    }
    my ($loginid_key) = grep { $decoded_data->{details}->{$_} } qw( loginid client_loginid );
    if ($loginid_key) {
        my $loginid = $decoded_data->{details}->{$loginid_key};
        $decoded_data->{sanitised_details} = {loginid => $loginid};
    }
    delete $decoded_data->{details};
    return encode_json_utf8($decoded_data);
}

1;


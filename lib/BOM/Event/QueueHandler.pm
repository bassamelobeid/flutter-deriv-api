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
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_text);
use BOM::Event::Services;
use BOM::Event::Process;
use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use Log::Any qw($log);
use BOM::Event::Utility qw(exception_logged);
use Clone qw( clone );
use Future::AsyncAwait;
use Net::Domain qw( hostname );
use Algorithm::Backoff;
use curry;
use Future::Utils qw(fmap0);
use List::Util qw( any );

use constant REQUESTS_PER_CYCLE => 5000;

=head2 CONSUMER_GROUP

Name of the Redis stream Consumer-Group

=cut

use constant CONSUMER_GROUP => 'GENERIC_EVENTS_CONSUMERS';

=head2 DEFAULT_QUEUE_WAIT_TIME

How long (in seconds) to wait for an event on each iteration.

=cut

use constant DEFAULT_QUEUE_WAIT_TIME => 10;

=head2 MAXIMUM_PROCESSING_TIME

How long (in seconds) to allow for the process
call to wait for L<BOM::Event::QueueHandler::process_job>.
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
than the L<MAXIMUM_JOB_TIME>.

=item * C<stream> - Stream name to monitor Redis stream or default monitor queue


=back

=cut

sub configure {
    my ($self, %args) = @_;
    for (qw(queue queue_wait_time maximum_job_time maximum_processing_time stream worker_index)) {
        $self->{$_} = delete $args{$_} if exists $args{$_};
    }
    return $self->next::method(%args);
}

=head2 services

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
    $self->services;
    $self->redis;

    return undef;
}

=head2 initialize_request_counter

initialize request counter

=cut

sub initialize_request_counter { shift->{request_counter} //= 0; return undef; }

=head2 queue_name

Returns the queue name which contains the events;

=cut

sub queue_name { return shift->{queue} }

=head2 stream_name

Returns te stream name which contains the events;

=cut

sub stream_name { return shift->{stream} }

=head2 host_name

Returns host name if defined otherwise returns machine's name
by default using L<Net::Domain>'s B<hostname> sub

=cut

sub host_name {
    my $self = shift;

    return $self->{host} //= hostname;
}

=head2 consumer_name

Returns a consumer to subscribe as;

=cut

sub consumer_name {
    my $self = shift;

    return join '-', ($self->host_name, $self->{worker_index} // 0);
}

=head2 init_stream

Return undef and Creates a Redis stream consumer group if the stream is not created it will be created using the MKSTREAM option.

=cut

async sub init_stream {
    my ($self) = @_;
    $self->initialize_request_counter;
    try {
        await $self->redis->connected;

        # $ means: the ID of the last item in the stream.
        # MKSTREAM subcommand as the last argument after the ID
        # to automatically create the stream, if it doesn't exist.
        await $self->redis->xgroup('CREATE', $self->stream_name, $self->CONSUMER_GROUP, '$', 'MKSTREAM');
        $log->tracef('Initalizing stream with a consumer group');

    } catch ($err) {
        if (($err) =~ /Consumer Group name already exists/) {
            await $self->_resolve_pending_messages;
            # Consumer group exists error will always occurre after the first init
            # so since we may use more than 1 worker, we have to ignore it.;
            return undef;
        } else {
            $log->errorf('An error occurred while initializing connection: %s', $err);
            die "Sorry, an error occurred while processing your request. $err";
        }
    }
    return undef;
}

=head2 queue_wait_time

Returns the current timeout while waiting for a message from redis

We should not cache this value as it could be changed in run-time

Note that the processing will be blocked until new data comes hence we
need a timeout.

=cut

sub queue_wait_time { return (shift->{queue_wait_time} // DEFAULT_QUEUE_WAIT_TIME) }

=head2 maximum_job_time

Returns the maximum timeout configured per an async job

We should not cache this value as it could be changed in run-time

=cut

sub maximum_job_time { return (shift->{maximum_job_time} // MAXIMUM_JOB_TIME) }

=head2 maximum_processing_time

Returns the maximum timeout configured for the processing of a job.

=cut

sub maximum_processing_time { return (shift->{maximum_processing_time} // MAXIMUM_PROCESSING_TIME) }

=head2 should_shutdown

Returns a L<Future> which can be marked as L<Future/done> to halt any further queue
processing.

=cut

async sub should_shutdown {
    my ($self) = @_;
    return $self->{should_shutdown} //= await $self->loop->new_future->set_label('QueueHandler::shutdown');
}

=head2 get_stream_item

Returns an item from a redis stream

=cut

async sub get_stream_item {
    my $self = shift;
    my $message;
    try {
        $message = await $self->redis->xreadgroup(
            GROUP => CONSUMER_GROUP,
            $self->consumer_name,
            BLOCK   => $self->queue_wait_time * 1000,    # BLOCK expects milliseconds
            COUNT   => 1,
            STREAMS => $self->stream_name,
            '>'                                          # Redis special ID which retrieve last id of group's messages
        );
    } catch ($err) {
        if (($err) =~ /^NOGROUP/) {
            # There is no consumer group for reading, suppress error and recreate one.
            # Note: it happens by purging Redis while the worker is working, common in testing.
            $log->errorf('Redis exception: %s', $err);
            await $self->init_stream;
        } else {
            $log->errorf('An exception occurred while processing events stream request: %s', $err);
        }
    }
    return undef unless $message;

    $self->{request_counter}++;
    $log->debugf("Got stream item: %s", $message);

    return {
        event_id => $message->[0]->[1]->[0]->[0],
        event    => $message->[0]->[1]->[0]->[1]->[1]};
}

=head2 stream_process_loop

Returns the L<Future> representing the processing loop, starting it if required.

This is the main logic for waiting on events from the Redis stream and calling the
appropriate handler.

=cut

async sub stream_process_loop {
    my $self = shift;
    await $self->init_stream;

    while (!$self->should_shutdown->is_ready() && $self->{request_counter} <= REQUESTS_PER_CYCLE) {
        my $item = await $self->get_stream_item();
        # $item will be undef in case of timeout occurred
        next unless $item;

        my $decoded_data;
        try {
            $decoded_data = decode_json_utf8($item->{event});
            stats_inc(lc $self->stream_name . ".read");
        } catch ($err) {
            stats_inc(lc $self->stream_name . ".invalid_data");
            # Invalid data indicates serious problems, we halt
            # entirely and record the details
            $log->errorf('Bad data received from stream causing exception %s', $err);
            exception_logged();
        }

        # redis message will be undef in case of timeout occurred
        await $self->process_job($self->stream_name, $decoded_data);
        await $self->_ack_message($item->{event_id});
    }
}

=head2 get_queue_item

Returns a item from redis list

=cut

async sub get_queue_item {
    my $self       = shift;
    my $queue_item = await $self->redis->brpop(
        # We don't cache these: each iteration uses the latest values,
        # allowing ->configure to change name and wait time dynamically.
        $self->queue_name,
        $self->queue_wait_time
    );
    $log->debugf("Got queue item: %s", $queue_item);
    return $queue_item;
}

=head2 queue_process_loop

Returns the L<Future> representing the processing loop, starting it if required.

This is the main logic for waiting on events from the Redis queue and calling the
appropriate handler.

=cut

async sub queue_process_loop {
    my $self = shift;
    while (!$self->should_shutdown->is_ready()) {
        my $item = await $self->get_queue_item();
        # $item will be undef in case of timeout occurred
        next unless $item;
        my ($queue_name, $event_data) = $item->@*;
        my $decoded_data;
        try {
            $decoded_data = decode_json_utf8($event_data);
            stats_inc(lc "$queue_name.read");
        } catch ($err) {
            stats_inc(lc "$queue_name.invalid_data");
            # Invalid data indicates serious problems, we halt
            # entirely and record the details
            $log->errorf('Bad data received from queue causing exception %s', $err);
            exception_logged();
        }

        # redis message will be undef in case of timeout occurred
        await $self->process_job($queue_name, $decoded_data);
    }
}

=head2 _resolve_pending_messages

Acknowledge all pending message unconditionally.

- Since we have no idea about safety of messages reprocessing,
every time new worker started, we try to mark all pending
messages which have same consumer name as acknowledged.

- In future phases we will support retrying mechanism for all
one-way request which expect no response from server-side.

Returns undef

=cut

async sub _resolve_pending_messages {
    my $self = shift;
    try {
        my $result = await $self->redis->xpending($self->stream_name, CONSUMER_GROUP, '-', '+', '10000', $self->consumer_name);
        # Since await is not allowed inside foreach on a non-lexical iterator variable
        await &fmap0(    ## no critic
            $self->$curry::weak(
                async sub {
                    my ($self, $msg) = @_;
                    await $self->_ack_message($msg->[0]);
                }
            ),
            foreach    => $result,
            concurrent => 4,
        );
    } catch ($err) {
        $log->errorf('Failed while resolving pending messages in (%s) stream: %s', $self->stream_name, $err);
    }

    return undef;
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
        my $f   = Future->wrap($res);
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
    } catch ($e) {
        $log->errorf('Failed to process data (%s) - %s', $self->clean_data_for_logging($event_data), $e);
        exception_logged();
        # This one's less clear cut than other failure cases:
        # we *do* expect occasional failures from processing,
        # and normally that does not imply everything is broken.
        # However, continuous failures should perhaps be treated
        # more seriously?
        return Future->done;
    } finally {
        alarm(0);
    }
}

=head2 _ack_message

Mark message as acknowledged by consumer group

=over 4

=item * C<$id> - The message id

=back

Returns undef

=cut

async sub _ack_message {
    my ($self, $id) = @_;
    try {
        await $self->redis->xack($self->stream_name, $self->CONSUMER_GROUP, $id);
    } catch ($err) {
        $log->errorf('Failed while marking message_id as acknowledged with Error: %s', $err);
    }
    return undef;
}

=head2 clean_data_for_logging

Description: Cleans out any data that might be GDPR sensitive when the log level is not debug.

Takes the following arguments

=over 4

=item * C<$event_data> - A JSON string or HashRef containing the event data.

=back

Returns a JSON string with sanitized event data

=cut

sub clean_data_for_logging {
    my ($self, $event_data) = @_;
    # Event Data looks like {"details":{"loginid":"CR2000000"},"context":{"language":"EN","brand_name":"binary"},"type":"api_token_deleted"}
    # Where "details" is the values passed with the event and "type" is the name of the event.
    if ($log->is_debug()) {
        return $event_data;
    }
    my $decoded_data;
    try {
        # decode_json only when we are passed the original raw JSON bytes.
        # Otherwise, we take a deep copy of the entire hashref to avoid changing anything in the original.
        $decoded_data = ref($event_data) ? clone($event_data) : decode_json_utf8($event_data);
    } catch ($e) {
        exception_logged();
        return "Invalid JSON format event data";
    }
    my ($loginid_key) = grep { $decoded_data->{details}->{$_} } qw( loginid client_loginid );
    if ($loginid_key) {
        my $loginid = $decoded_data->{details}->{$loginid_key};
        $decoded_data->{sanitised_details} = {loginid => $loginid};
    }
    delete $decoded_data->{details};
    return encode_json_text($decoded_data);
}

1;

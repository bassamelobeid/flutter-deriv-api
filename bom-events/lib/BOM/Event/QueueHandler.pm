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
use Scalar::Util    qw(blessed);
use Future::Utils   qw(repeat);
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_text);
use BOM::Event::Services;
use BOM::Event::Process;
use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use Log::Any                   qw($log);
use BOM::Event::Utility        qw(exception_logged);
use Clone                      qw( clone );
use Future::AsyncAwait;
use Net::Domain qw( hostname );
use Algorithm::Backoff;
use curry;
use Future::Utils qw(fmap0);
use List::Util    qw( any first );
use BOM::Config;
use UUID::Tiny;

use constant REQUESTS_PER_CYCLE => 5000;

=head2 DEFAULT_QUEUE_WAIT_TIME

How long (in seconds) to wait for an event on each iteration.

=cut

use constant DEFAULT_QUEUE_WAIT_TIME => 10;

=head2 MAXIMUM_JOB_TIME

How long (in seconds) to allow for a single job call is allowed.

=cut

use constant MAXIMUM_JOB_TIME => 30;

=head2 PENDING_ITEMS_COUNT

How many items are we looking for in the pending queue

=cut

use constant PENDING_ITEMS_COUNT => 100;

=head2 NUMBER_OF_RETRIES

How many times are we reprocessing the items

=cut

use constant NUMBER_OF_RETRIES => 5;

=head2 configure

Called from the constructor and can also be used manually to update
values.

Takes the following named parameters:

=over 4

=item * C<queue> - the queue name to monitor

=item * C<queue_wait_time> - how long (in seconds) to wait for events

=item * C<maximum_job_time> - total amount of a time a single job is
allowed to take.

=item * C<streams> - Stream names to monitor

=item * C<category> - Type of jobs to process, default is generic.

=item * C<worker_index> - Index of this worker, default is 0.

=item * C<retry_interval> - How often do we retry an event (in milliseconds).

=back

=cut

sub configure {
    my ($self, %args) = @_;
    for (qw(queue queue_wait_time maximum_job_time streams category worker_index retry_interval)) {
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

=head2 streams

Returns array of streams to listen to.

=cut

sub streams { return shift->{streams}->@* }

=head2 category

Returns the category of jobs we should process, defaults to generic.

=cut

sub category { return shift->{category} // 'generic' }

=head2 consumer_group

Returns the consumer group name, which will be same for all streams.

=cut

sub consumer_group {
    my $self = shift;

    return uc($self->category) . '_EVENTS_CONSUMERS';
}

=head2 consumer_name

Returns a unique identifier to be used within a consumer group.

=cut

sub consumer_name {
    my $self = shift;

    return join '-', ($self->host_name, $self->{worker_index} // 0);
}

=head2 job_processor

Returns the BOM::Event::Process instance for processing jobs.

=cut

sub job_processor {
    my $self = shift;

    return $self->{job_processor} //= BOM::Event::Process->new(category => $self->category);
}

=head2 retry_interval

Returns the retry interval to be used when claiming an item from stream

=cut

sub retry_interval { return shift->{retry_interval} // 0 }

=head2 host_name

Returns host name if defined otherwise returns machine's name
by default using L<Net::Domain>'s B<hostname> sub

=cut

sub host_name {
    my $self = shift;

    return $self->{host} //= hostname;
}

=head2 init_streams

Return undef and Creates a Redis stream consumer group if the stream is not created it will be created using the MKSTREAM option.

=cut

async sub init_streams {
    my ($self) = @_;
    $self->initialize_request_counter;
    await $self->redis->connected;
    for my $stream ($self->streams) {
        try {
            # $ means: the ID of the last item in the stream.
            # MKSTREAM subcommand as the last argument after the ID
            # to automatically create the stream, if it doesn't exist.
            await $self->redis->xgroup('CREATE', $stream, $self->consumer_group, '$', 'MKSTREAM');
            $log->debugf("Created consumer group '%s' on stream %s", $self->consumer_group, $stream);
        } catch ($err) {
            if (($err) =~ /Consumer Group name already exists/) {
                my $action = $self->retry_interval ? "retried" : "acknowledged";
                $log->debugf("Consumer group '%s' already exsits on stream %s; all pending messages will be %s.",
                    $self->consumer_group, $stream, $action);
                await $self->_resolve_pending_messages($stream);
                # Consumer group exists error will always occurre after the first init
                # so since we may use more than 1 worker, we have to ignore it.;
                next;
            } else {
                $log->errorf('Failed to create consumer group on stream %s: %s', $stream, $err);
                die "Sorry, an error occurred while processing your request. $err";
            }
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

=head2 should_shutdown

Returns a L<Future> which can be marked as L<Future/done> to halt any further queue
processing.

=cut

sub should_shutdown {
    my ($self) = @_;
    return $self->{should_shutdown} //= $self->loop->new_future->set_label('QueueHandler::shutdown');
}

=head2 get_stream_items

Gets an item from each stream, may return multiple items if there are multiple streams.

=cut

async sub get_stream_items {
    my $self = shift;
    my $message;

    await $self->redis->connected;

    try {
        $message = await $self->redis->xreadgroup(
            'GROUP',   $self->consumer_group, $self->consumer_name,
            'BLOCK',   $self->queue_wait_time * 1000,    # BLOCK expects milliseconds
            'COUNT',   1,
            'STREAMS', $self->streams,
            map { '>' } 1 .. $self->streams,             # Redis special ID which retrieve last id of group's messages
        );
    } catch ($err) {
        if (($err) =~ /^NOGROUP/) {
            # There is no consumer group for reading, suppress error and recreate one.
            # Note: it happens by purging Redis while the worker is working, common in testing.
            $log->errorf('Redis exception: %s', $err);
            await $self->init_streams;
        } else {
            $log->errorf('An exception occurred while processing events stream request: %s', $err);
        }
    }
    return undef unless $message;    # xreadgroup timed out

    $self->{request_counter}++;
    $log->debugf("Got stream item(s): %s", $message);

    # message will in this format: [ ['GENERIC_EVENTS_STREAM', [ ['1639375311383-0', { event => '{}' ] ] ] ], ['DOCUMENT_AUTHENTICATION_STREAM', [ ['1639375311384-0', { event => '{}' ] ] ] ] ]

    my @items = map { {stream => $_->[0], id => $_->[1]->[0]->[0], event => $_->[1]->[0]->[1]->[1]} } @$message;
    return \@items;
}

=head2 stream_process_loop

Returns the L<Future> representing the processing loop, starting it if required.

This is the main logic for waiting on events from the Redis stream and calling the
appropriate handler.

=cut

async sub stream_process_loop {
    my $self = shift;

    await $self->init_streams;

    while (!$self->should_shutdown->is_ready() && $self->{request_counter} <= REQUESTS_PER_CYCLE) {
        my $items;

        # If there are items to reprocess, retrieve them
        if ($self->retry_interval) {
            $items = await $self->items_to_reprocess;
        }

        # If no items to reprocess, fetch new items from the stream
        $items = await $self->get_stream_items unless $items;

        my $processed_job;

        # Process each item from the stream
        ITEM:
        for my $item (@$items) {
            my ($stream, $id, $event, $retry_count) = $item->@{qw/stream id event retry_count/};

            if ($processed_job) {
                # If this returns false, the message has been claimed by another consumer and should be skipped
                next ITEM unless await $self->_reclaim_message($stream, $id);
            }

            $retry_count //= 1;

            my $decoded_data;
            try {
                # Attempt to decode the event data
                $decoded_data = decode_json_utf8($event);
                stats_inc("$stream.read");
            } catch ($err) {
                # Log and handle invalid data
                stats_inc("$stream.invalid_data");
                $log->errorf('Bad data received from stream %s: %s', $stream, $err);
                exception_logged();
            }

            # Setting retry_count
            $log->debugf('Retry count: %s', $retry_count);
            if ($retry_count == NUMBER_OF_RETRIES) {
                $decoded_data->{details}->{retry_last} = 1;
            }

            # Build the context for any needed service access, ideally at some point the correlation_id
            # will be passed in from the event itself rather than randomly generating it. When/if it does
            # we're ready and waiting
            my $service_contexts = {
                user => {
                    correlation_id => UUID::Tiny::create_UUID_as_string(UUID::Tiny::UUID_V4),
                    auth_token     => "Unused but required to be present",
                    environment    => hostname() . ' ' . 'BOM::Events::QueueHandler ' . $$,
                },
            };

            try {
                # NOTE : At this point it is not guaranteed that
                # an event will be processed at most once since a
                # job can be successful but not acknowledged,
                # thus keeping it 'pending'
                my $response = await $self->process_job($stream, $decoded_data, $service_contexts);

                if (blessed($response) && $response->isa('Future')) {
                    die $response->failure if $response->failure;
                }

                # Acknowledge the successful processing of the message
                await $self->_ack_message($stream, $id);

                $log->debugf("Event '%s' from stream '%s' processed successfully", $decoded_data->{type}, $stream);
            } catch ($e) {
                if ($retry_count >= NUMBER_OF_RETRIES || !$self->retry_interval) {
                    # Log the error, update stats, and acknowledge the message
                    $log->error($e);
                    stats_inc("$stream.processed.failure", {tags => ["event:$decoded_data->{type}"]});
                    await $self->_ack_message($stream, $id);
                    exception_logged();
                    $log->infof("Event '%s' from stream '%s' processed with failure", $decoded_data->{type}, $stream);
                    next ITEM;
                }

                # Log the error and initiate reprocessing for the event
                $log->debugf("Event '%s' from stream '%s' failed to process. The initial error was: %s. Reprocessing the event.",
                    $decoded_data->{type}, $stream, $e);
            } finally {
                $processed_job = 1;
            }
        }
    }

}

=head2 items_to_reprocess

Retry mechanism for events.

Looks for items in the pending queue and returns one if it needs to be retried

=cut

async sub items_to_reprocess {

    my $self = shift;

    STREAM:
    for my $stream ($self->streams) {

        try {
            my $first_id = '-';

            while (my $pending_items = await $self->redis->xpending($stream, $self->consumer_group, $first_id, '+', PENDING_ITEMS_COUNT)) {

                ITEM:
                # This 'for' loop can be avoided once
                # we pass to Redis version 6.2+ where
                # we will be able to include IDLE_TIME
                # filter for XPENDING
                for my $item ($pending_items->@*) {
                    my $id        = $first_id = $item->[0];
                    my $idle_time = $item->[2];

                    next ITEM if $idle_time < $self->retry_interval;

                    my $claimed_item = await $self->redis->xclaim($stream, $self->consumer_group, $self->consumer_name, $self->retry_interval, $id);

                    # Go to the next item if there are no items to claim
                    next ITEM unless @$claimed_item;

                    # The reason for "+ 1" is that the item
                    # has been reclaimed, so the count in
                    # the stream has been increased, but
                    # since we are getting the retry count
                    # from XPENDING, we will need to
                    # increment it by 1
                    my $retry_count  = $item->[3] + 1;
                    my $event        = $claimed_item->[0]->[1]->[1];
                    my $decoded_info = decode_json_utf8($event);
                    stats_inc("$stream.event_retried", {tags => ["event:$decoded_info->{type}"]});

                    if ($retry_count > NUMBER_OF_RETRIES) {
                        await $self->_ack_message($stream, $id);
                        $log->errorf("Exceeded number of retries for '%s' event from '%s'", $decoded_info->{type}, $stream);
                        next ITEM;
                    }

                    $log->debugf("Reprocessing event '%s' from '%s', attempt # %s/%s",
                        $decoded_info->{type}, $stream, $retry_count, NUMBER_OF_RETRIES);

                    my @items =
                        map { {stream => $stream, id => $_->[0]->[0], event => $_->[0]->[1]->[1], retry_count => $retry_count} } $claimed_item;

                    return \@items;
                }

                next STREAM if @{$pending_items} < PENDING_ITEMS_COUNT;
            }
        } catch ($e) {
            $log->errorf("Error while fetching items to reprocess from '%s' : '%s'", $stream, $e);
        }
    }

    return;
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

        # Build the context for any needed service access, ideally at some point the correlation_id
        # will be passed in from the event itself rather than randomly generating it. When/if it does
        # we're ready and waiting
        my $service_contexts = {
            user => {
                correlation_id => UUID::Tiny::create_UUID_as_string(UUID::Tiny::UUID_V4),
                ,
                auth_token  => "Unused but required to be present",
                environment => hostname() . ' ' . 'BOM::Events::QueueHandler ' . $$,
            },
        };

        # redis message will be undef in case of timeout occurred
        await $self->process_job($queue_name, $decoded_data, $service_contexts);
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
    my ($self, $stream) = @_;

    if (!$self->retry_interval) {
        try {
            my $result = await $self->redis->xpending($stream, $self->consumer_group, '-', '+', '10000', $self->consumer_name);
            # Since await is not allowed inside foreach on a non-lexical iterator variable
            await &fmap0(    ## no critic
                $self->$curry::weak(
                    async sub {
                        my ($self, $msg) = @_;
                        await $self->_ack_message($stream, $msg->[0]);
                    }
                ),
                foreach    => $result,
                concurrent => 4,
            );
        } catch ($err) {
            $log->errorf('Failed while resolving pending messages in (%s) stream: %s', $stream, $err);
        }
    }

    return undef;
}

=head2 process_job

Description: Handles the timeouts and launching the processing of the actual jobs. Not in-lined so that it can be more easily tested.
Takes the following arguments

=over 4

=item - $stream : The name of the redis stream (or queue) the job is from

=item - $event_data : The Data that was passed to the event.

=back

Returns a L<FUTURE>

=cut

async sub process_job {
    my ($self, $stream, $event_data, $service_contexts) = @_;

    try {
        # A handler might be a sync sub or an async sub
        # Future->wrap will return immediately if it has a scalar
        # Due to Perl stack refcounting issues, we occasionally see exceptions here with
        # a message like "Can't call method "wrap" without a package or object reference"
        # - storing in an intermediary variable here to keep the result alive long enough
        # for Future->wrap to work. Note that the actual stack element which Perl complains about
        # is just the class name (the string 'Future') - this would likely need some quality time with gdb
        # to dissect fully.
        my $res      = $self->job_processor->process($event_data, $stream, $service_contexts);
        my $f        = Future->wrap($res);
        my $job_time = $self->maximum_job_time;

        # selective max job time per event, for QA use only e.g.: CLIENT_VERIFICATION_MAXIMUM_JOB_TIME="1"
        $job_time = $ENV{uc($event_data->{type} . '_MAXIMUM_JOB_TIME')} // $self->maximum_job_time if BOM::Config::on_qa() && $event_data->{type};

        return await Future->wait_any($f, $self->loop->timeout_future(after => $job_time));
    } catch ($e) {
        my $cleaned_data = $self->clean_data_for_logging($event_data);

        my $error_msg;

        if ($e =~ /^Watchdog timeout|^Timeout/i) {
            $error_msg = $log->debugf("Processing of request from stream %s took longer than 'MAXIMUM_JOB_TIME' %s seconds - data was %s",
                $stream, $self->maximum_job_time, $cleaned_data);
        } else {
            $error_msg = $log->debugf('Failed to process data (%s) - %s', $cleaned_data, $e);
        }

        # This one's less clear cut than other failure cases:
        # we *do* expect occasional failures from processing,
        # and normally that does not imply everything is broken.
        # However, continuous failures should perhaps be treated
        # more seriously?
        return Future->fail($error_msg);
    }
}

=head2 _ack_message

Mark message as acknowledged by consumer group

=over 4

=item * C<$stream> - The origin stream

=item * C<$id> - The message id

=back

Returns undef

=cut

async sub _ack_message {
    my ($self, $stream, $id) = @_;
    try {
        await $self->redis->xack($stream, $self->consumer_group, $id);
    } catch ($err) {
        $log->errorf('Failed to acknowledge message id %s in stream %s: %s', $id, $stream, $err);
    }
    return undef;
}

=head2 _reclaim_message

Checks the message has not been claimed by someone else, and resets its idle time.

=over 4

=item * C<$stream> - The origin stream

=item * C<$id> - The message id

=back

Returns 1 if the message is valid to be processed, otherwise 0.

=cut

async sub _reclaim_message {
    my ($self, $stream, $id) = @_;

    try {
        # xpending is to get an accurate idle time and delivery count
        my $pending = await $self->redis->xpending($stream, $self->consumer_group, $id, $id, 1, $self->consumer_name);

        unless ($pending and @$pending) {
            $log->debugf('message %s from stream %s is no longer pending, skipping it', $id, $stream);
            return 0;
        }

        my $claim = await $self->redis->xclaim(
            $stream,
            $self->consumer_group,
            $self->consumer_name,
            $pending->[0][2],                  # idle time filter, ensures nobody else xclaimed since we called xpending
            $id,
            'retrycount', $pending->[0][3],    # keep delivery count the same as it was
        );

        unless ($claim) {
            $log->debugf('could not xclaim message %s from stream %s, skipping it', $id, $stream);
            return 0;
        }

        $log->debugf('successfully reclaimed message %s from stream %s: %s', $id, $stream, $claim);
        return 1;

    } catch ($err) {
        $log->errorf('failed to reclaim message %s in stream %s: %s', $id, $stream, $err);
        return 0;    # don't process this item, safer than risk double processing
    }
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

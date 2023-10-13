package BOM::Event::Script::OnfidoPDF;

=head1 NAME

BOM::Event::Script::OnfidoPDF

=head1 DESCRIPTION

This packages provides a set of testable functions regarding the collecting of Onfido Check PDFs.

=cut

use strict;
use warnings;
use BOM::User::Onfido;
use Future::AsyncAwait;
use BOM::Platform::Event::Emitter;
use IO::Async::Loop;
use BOM::Event::Services;
use Log::Any qw($log);

# Declare constants here

use constant ONFIDO_PDF_CHECK_ENQUEUED => 'ONFIDO::PDF::CHECK::ENQUEUED::';
use constant ONFIDO_PDF_CHECK_HITS     => 'ONFIDO::PDF::CHECK::HITS::';
use constant ONFIDO_PDF_QUEUE_SIZE     => 'ONFIDO::PDF::QUEUE::SIZE';
use constant ONFIDO_PDF_HITS_TTL       => 259200;
use constant ONFIDO_PDF_CHECK_TTL      => 5400;
use constant CHECKS_PER_HOUR           => 1260;
use constant MAX_HITS_PER_CHECK        => 3;

# Declare here the services we'll be using.

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

=head2 run

Entrypoint for the PDF downloader script

Fetches complete Onfido checks in the `pending` PDF status.

Attempts to emit a `onfido_check_completed` which will execute the downloading process.

In general, this packages takes care of queue growth and redundant check processing.

=cut

async sub run {
    my ($self) = @_;

    my $limit = await $self->get_batch_size;

    DataDog::DogStatsd::Helper::stats_histogram('event.onfido.pdf.batch_size', $limit);

    return undef unless $limit;

    my $checks = BOM::User::Onfido::get_pending_pdf_checks($limit);

    DataDog::DogStatsd::Helper::stats_histogram('event.onfido.pdf.fetch_size', scalar $checks->@*);

    my $redis = $services->redis_events_write();

    await $redis->connect;

    for my $check ($checks->@*) {
        my $check_id = $check->{id};

        # dont repeat the event for this check

        next unless await $redis->set(ONFIDO_PDF_CHECK_ENQUEUED . $check_id, 1, 'EX', ONFIDO_PDF_CHECK_TTL, 'NX');

        # flag the check as failed if hit too many times

        my $hits = await $redis->incr(ONFIDO_PDF_CHECK_HITS . $check_id);

        if ($hits > MAX_HITS_PER_CHECK) {
            await $redis->del(ONFIDO_PDF_CHECK_HITS . $check_id);

            BOM::User::Onfido::update_check_pdf_status($check_id, 'failed');

            DataDog::DogStatsd::Helper::stats_inc('event.onfido.pdf.failed');

            $log->infof('Onfido PDF downloader: giving up on check with id = %s', $check_id);

            next;
        }

        await $redis->expire(ONFIDO_PDF_CHECK_HITS . $check_id, ONFIDO_PDF_HITS_TTL);

        DataDog::DogStatsd::Helper::stats_inc('event.onfido.pdf.emit');

        # unfortunately our events service has no scheduler available
        # would be splendind to distribute the messages evenly across the 1hour timespan
        # best we can do is to enqueue all of these and let the 21 worker do their thing.

        BOM::Platform::Event::Emitter::emit(
            'onfido_check_completed',
            {
                check_id       => $check_id,
                queue_size_key => ONFIDO_PDF_QUEUE_SIZE,    # this param hints the event to decrease the queue size
            });

        await $redis->incr(ONFIDO_PDF_QUEUE_SIZE);
    }

    return undef;
}

=head2 get_batch_size

Determines how many checks the consumer could cope with.

We might not want to clog the event queues with PDF downloads, disrupting the actual operational services.

Returns a L<Future> which resolves to an integer.

=cut

async sub get_batch_size {
    my $redis = $services->redis_events_write();

    await $redis->connect;

    my $queue_size = await $redis->get(ONFIDO_PDF_QUEUE_SIZE);

    $queue_size //= 0;

    # Crunching the numbers.
    #
    # There is evidence we currently have 21 workers dispatching the events queue.
    # What's more, the DOCUMENT_AUTHENTICATION_STREAM seems to be idle most of the time.
    # Still we don't want to clog the queue!!!
    #
    # We would like to process ~1 PDF per minute per worker.
    # Since the cronjob will hit hourly there is a 60 * 21 = 1260 base limit, per cronjob hit.
    #
    # At this rate we would process ~900k records in ~30 days.

    my $limit = CHECKS_PER_HOUR - $queue_size;

    $log->infof('Onfido PDF downloader:queue size is = %d, skipping cronjob run', $queue_size) if $limit <= 0;

    return 0 if $limit < 0;

    return $limit;
}

1;

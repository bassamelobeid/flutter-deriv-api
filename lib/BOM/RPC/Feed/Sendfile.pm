package BOM::RPC::Feed::Sendfile;
use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use mro;
use IO::AsyncX::Sendfile;

use Future::AsyncAwait;
use Time::Moment;
use Fcntl qw(:seek);
use List::UtilsBy qw(extract_by);
use Scalar::Util qw(blessed refaddr);
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing stats_gauge stats_event);

use Path::Tiny;
use Log::Any qw($log);

use constant BYTES_PER_TICK   => 4;
use constant MAX_OPEN_HANDLES => 6;

=pod

The LRU cache tracks available handles.

These are stored as an array of L<Future> instances, each entry
is an arrayref containing:

=over 4

=item * C<key> - composed from the symbol and the date

=item * C<future> - resolved with the file handle when this item is no longer being used

=back

For each request, we first look up the handle and transfer to the head of the
queue.

If the handle is not found, and our LRU cache is not yet full, we insert a new
item at the head of the queue containing an unresolved L<Future>.

If the LRU cache is already full, we pop the last entry in the queue, insert
a new unresolved L<Future> at the head of the queue, and await completion of the
previous last LRU entry.

In both these last cases, we resolve the L<Future> with the handle, underlying
and date once the sendfile request is complete.

=head2 stream_tick_range

The filehandle hash contains open handles for the daily data.

Each entry is a L<Future> which will resolve once the current operation is complete.

=over 4

=item * C<underlying> - which symbol to use

=item * C<start> - the epoch time at which to start reading data

=item * C<duration> - number of seconds to send

=item * C<stream> - the L<IO::Async::Stream> to send data on

=back

=cut

async sub stream_tick_range {
    my ($self, %args) = @_;

    my $stream = delete $args{stream} or die 'need a stream';
    my $underlying = $args{underlying};
    die 'duration should be > 0' unless 0 < (my $duration = delete $args{duration});
    my $start = Time::Moment->from_epoch($args{start} || die 'need a start time');

    my $day  = $start->at_midnight;
    my $date = $start->strftime('%Y-%m-%d');
    stats_inc('local_feed.reader.new_request', {tags => ['symbol:' . $underlying]});
    if ($day->plus_seconds($duration)->strftime('%Y-%m-%d') ne $date) {
        stats_inc('local_feed.reader.fail', {tags => ['symbol:' . $underlying, 'date:' . $date, 'error:duration']});
        die 'spans more than one day';
    }

    my $offset = BYTES_PER_TICK * ($start->epoch - $day->epoch);
    my $size   = BYTES_PER_TICK * ($duration);

    my %handle_args = (
        underlying => $underlying,
        date       => $day
    );
    # We have this nested construction because we need to mark the LRU slot as available on
    # completion, and it's a bit awkward to have the two things calling each other.
    await $self->with_handle(
        async sub {
            my ($fh) = @_;

            # Check if return is not a File Handler.
            if (ref($fh) ne 'GLOB' && $fh->is_failed) {
                my ($exception, $category) = $fh->failure;
                my $item = $self->extract_handle(%handle_args);
                # we are not going to send anything as the file couldnt be open.
                $stream->write(pack N1 => 0);
                $item->[1]->cancel();
                $self->close_handle($item);
                stats_inc('local_feed.reader.fail', {tags => ['symbol:' . $underlying, 'date:' . $date, 'error:' . $category]});
                $log->debugf("Failure openning file: %s | %s", $exception, $category);
                return;
            }

            # ->sendfile takes the current position, so we seek manually first
            $log->tracef('Seek to offset %d', $offset);
            $fh->seek($offset, SEEK_SET) or die 'cannot seek to target offset';

            # We deliberately don't `await` the write, because we want the sendfile
            # to be cued up immediately on this connection.
            $stream->write(pack N1 => $size);
            my $pending = $size;
            while ($pending > 0) {
                my $bytes = await $stream->sendfile(
                    fh     => $fh,
                    length => $size
                );

                die 'No bytes transferred' unless $bytes;
                $log->warnf('Failed to transfer expected size %d (had %d instead)', $size, $bytes) unless $size == $bytes;
                $pending -= $bytes;
            }
            stats_gauge('local_feed.reader.bytes_sent', $size, {tags => ['symbol:' . $underlying]});
            stats_inc('local_feed.reader.request_served', {tags => ['symbol:' . $underlying]});
            return;
        },
        %handle_args
    );
}

sub lru_cache { shift->{lru_cache} //= [] }

sub filename_for {
    my ($self, %args) = @_;
    my $date = $args{date};
    $self->base_path->child($args{underlying})->child($date->year)->child($date->strftime('%Y-%m-%d') . '.fullfeed.dat');
}

=head2 unshift_handle

Adds (unshift) new item in LRU cache array.

Expects the following named parameters:

=over 4

=item * C<underlying> - which underlying this handle represents

=item * C<date> - the date for which this filehandle is valid

=back

Returns a L<Future>

=cut

sub unshift_handle {
    my ($self, %args) = @_;

    my $k = join "\0", $args{underlying}, $args{date}->strftime('%Y-%m-%d');
    unshift $self->lru_cache->@*, [$k, my $f = $self->loop->new_future,];

    return $f;
}

=head2 extract_handle

Search LRU cache array for handle and extracts it if found. It pops the last handle if no arguments are passed.

Expects the following named parameters:

=over 4

=item * C<underlying> - which underlying this handle represents

=item * C<date> - the date for which this filehandle is valid

=back

Returns an LRU cached item.

=cut

sub extract_handle {
    my ($self, %args) = @_;

    return pop $self->lru_cache->@* if !%args;

    my $k = join "\0", $args{underlying}, $args{date}->strftime('%Y-%m-%d');
    # get handler if it exists in cache.
    my ($item) = extract_by { $_->[0] eq $k } $self->lru_cache->@*;
    return $item;
}

=head2 open_handle

Opens a read-only filehandle for a binary feed file.

Expects the following named parameters:

=over 4

=item * C<underlying> - which underlying this handle represents

=item * C<date> - the date for which this filehandle is valid

=back

Returns an L<IO::Handle> instance.

=cut

sub open_handle {
    my ($self, %args) = @_;
    my $filename = $self->filename_for(
        underlying => $args{underlying},
        date       => $args{date},
    );
    if ($filename->is_file) {
        # File size must always be 4(bytes) * 86400(seconds) = 345600(bytes)
        if ($filename->stat->[7] == 345600) {
            $log->debugf('Opening %s', $filename);
            open my $fh, '<:raw', $filename or return Future->fail('cannot open ' . $filename . ' - ' . $!);
            return $fh;
        } else {
            return Future->fail($filename, 'empty_file');
        }
    } else {
        return Future->fail($filename, 'not_a_file');
    }
}

=head2 close_handle

Closes a read-only filehandle for a binary feed file.

Expects the following named parameters:

=over 4

=item * L<IO::Handle> - which handle is going to be closed

=back

=cut

async sub close_handle {
    my ($self, $item) = @_;
    my $fh = await $item->[1];
    $log->tracef('Closing original handle %d', $fh->fileno);
    $fh->close or $log->errorf('Failed to close - %s', $!);
    return;
}

=head2 with_handle

Retrieves or opens a handle to the required feed file, and passes it
to a sub.

Expects a single coderef, then the following named parameters:

=over 4

=item * C<underlying> - which underlying this handle represents

=item * C<date> - the date for which this filehandle is valid

=back

The coderef will be called with an L<IO::Handle> instance which is
guaranteed to be open for read and not in use by any other sendfile/seek
operation.

Returns a L<Future>.

=cut

async sub with_handle {
    my ($self, $code, %args) = @_;
    # we need to reopen file handler if its today, to make sure we got the latest update on file.
    my $diff_to_today = $args{date}->delta_days(Time::Moment->now);
    # get handler if it exists in cache.
    my $item = $self->extract_handle(%args);
    # Add item to the starting of cache array
    my $f = $self->unshift_handle(%args);
    # File handler to be used by item.
    my $fh;

    if ($item && $diff_to_today) {
        $log->debugf('Found item in LRU cache, awaiting and using it (state is %s)', $item->[1]->state);
        $fh = await $item->[1];
        # Just to check how effictive caching is.
        stats_inc('local_feed.reader.handle_reuse', {tags => ['symbol:' . $args{underlying}]});
    } elsif ($item && !$diff_to_today) {
        $log->debugf('Found item in LRU cache, but going to refresh it (state is %s)', $item->[1]->state);
        $self->close_handle($item);
        $fh = $self->open_handle(%args);
        stats_inc('local_feed.reader.handle_refresh', {tags => ['symbol:' . $args{underlying}]});
    } elsif ($self->lru_cache->@* < MAX_OPEN_HANDLES) {
        $log->debugf('LRU cache is not yet full, adding a new entry');
        $fh = $self->open_handle(%args);
    } else {
        $log->debugf('LRU cache is full, will use last entry');
        my $old_item = $self->extract_handle();
        $self->close_handle($old_item);
        $fh = $self->open_handle(%args);
    }
    await $code->($fh);
    $f->done($fh);
    return;
}

sub base_path { shift->{base_path} }

sub configure {
    my ($self, %args) = @_;
    $self->{base_path} = path('' . delete($args{base_path})) if exists $args{base_path};
    return $self->next::method(%args);
}

1;


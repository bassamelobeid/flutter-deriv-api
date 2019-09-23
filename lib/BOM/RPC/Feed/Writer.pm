package BOM::RPC::Feed::Writer;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

=head1 NAME

BOM::RPC::Feed::TickPopulator - streams tick data from the database and feed client to local fixed-record files

=head1 DESCRIPTION

Since more ticks can be arriving while we're processing pending data, we use
an asynchronous database connection to pull data.

Any ticks delivered through Redis are accumulated and written to file once
all database content is populated.

We handle all the ticks in a single process currently, but the list of symbols
can be specified manually to distribute more fairly across CPUs.

=cut

no indirect;

use curry;

use Database::Async;
use Database::Async::Engine::PostgreSQL;
use List::UtilsBy qw(max_by);
use Net::Async::Redis;
use Future::AsyncAwait;

use JSON::MaybeUTF8 qw(:v1);
use BOM::Config::RedisReplicated;
use Finance::Underlying;
use Path::Tiny;
use Fcntl qw(:seek);
use Log::Any qw($log);
use Time::Moment;

use DataDog::DogStatsd::Helper qw(stats_inc stats_timing stats_gauge);
use Finance::Asset;

use POSIX qw(floor);
use BOM::RPC::Feed::Sendfile;

use constant BYTES_PER_TICK => 4;

=head2 subscribe_to_redis

Called when we want to subscribe to feed redis, in order to get the latest tick to be written to binary file.

Takes two parameters:

=over 4

=item * C<$symbol> - the symbol we want to subscribe to

=item * C<$pip_size> - the symbol pip size that is used to ensure price precision.

=back

Returns a future that will update tick binary file on every received tick.

=cut

async sub subscribe_to_redis {
    my ($self, $symbol, $pip_size) = @_;

    $log->debugf('subscribing to redis %s', $self->redis_source);
    my $cfg = BOM::Config::RedisReplicated::redis_config(feed => $self->redis_source);
    $self->add_child(
        my $redis = Net::Async::Redis->new(
            uri  => $cfg->{uri},
            port => $cfg->{port},
            auth => $cfg->{password},
        ));
    await $redis->connect;
    my $sub = await $redis->subscribe('DISTRIBUTOR_FEED::' . $symbol);
    return $sub->events->map('payload')->decode('UTF-8')->decode('json')->each(
        sub {
            my $tick      = shift;
            my $today     = Time::Moment->now;
            my $tick_time = Time::Moment->from_epoch($tick->{epoch});
            # Check if we start getting ticks for the next day, then reinitialize ticks array for the day.
            if ($tick_time >= $self->start->{$symbol}->plus_days(1)->at_midnight) {
                $self->_update_start_day($symbol);
            }
            my $tick_index = $tick_time->epoch - $self->start->{$symbol}->epoch;
            my $price = int floor(0.5 + ($tick->{quote} / $pip_size));
            $log->debugf('SYMBOL: %s | TICK: %s | EPOCH: %s | CALC: %s | INDEX: %s', $symbol, $tick->{quote}, $tick_time->epoch, $price, $tick_index);
            stats_timing(
                'local_feed.writer.latest_tick_time',
                $tick_time->delta_seconds(Time::Moment->now),
                {tags => ['symbol:' . $symbol, 'date:' . $tick_time->strftime('%Y-%m-%d')]});
            $self->write_tick($symbol, $self->start->{$symbol}, $price, $tick_index);
            stats_timing(
                'local_feed,writer.write_file_time',
                $today->delta_milliseconds(Time::Moment->now),
                {tags => ['symbol:' . $symbol, 'date:' . $tick_time->strftime('%Y-%m-%d')]});

        })->retain;
}

=head2 run

The main sub, its called to start creating binary feed files to all symbols.

=back

Waits for all Futures to be completed.

=cut

async sub run {
    my ($self) = @_;
    $log->debugf('RUN is starting... TIME: %s', time);
    await Future->needs_all(map { $self->process_symbol($_) } @{$self->symbols});
    $log->infof('Database querying is finished at: %s | running fully on Redis subscription', time);
    return;
}

=head2 _update_start_day

Called in order to set/increment start day and send stats for current symbol date being written.

=over 4

=item * C<$symbol> - the symbol we want to set its starting time.

=item * C<$date> - C<Time::Moment> object date to be set.

=back

returns if the update happened successfully.

=cut

sub _update_start_day {
    my ($self, $symbol, $date) = @_;

    $self->{start}->{$symbol} = $date ? $date : $self->start->{$symbol}->plus_days(1);
    # Prepopulate to make sure that inserting data doesn't conflict with streaming content
    # Initialize ticks array to be all zeros.
    # on every new day we should initialize this again.
    $self->{ticks}->{$symbol} = [(0) x (24 * 60 * 60)];
    my $diff_to_today = $self->start->{$symbol}->delta_days(Time::Moment->now);
    stats_gauge('local_feed.days_to_today', $diff_to_today, {tags => ['symbol:' . $symbol]});
    $log->debugf('setting start time: %s | Symbol: %s | diff to today %s', $self->start->{$symbol}, $symbol, $diff_to_today);

    # Allocate new file.
    my $filename = $self->sendfile->filename_for(
        underlying => $symbol,
        date       => $self->{start}->{$symbol},
    );
    $filename->parent->mkpath;
    open my $fh, '>:raw', $filename or die("Unable to open file for writing $filename");
    truncate($fh, 86400 * BYTES_PER_TICK);
    close($fh);
    return;
}

=head2 find_start

Called when first try to run, in order to obtain the right time to start with.

=over 4

=item * C<$symbol> - the symbol we want to find start time for it.

=back

sets C<BOM::RPC::Feed::Writer::start>

=cut

async sub find_start {
    my ($self, $symbol) = @_;

    # Although we technically only need the last N years of data,
    # might as well populate from the earliest history we have:
    # this means that our official feed replica can control how
    # far back our data goes.
    $log->debugf('getting symbol first_insert_date');
    my $first_insert = await $self->feed->query(
        q{-- rpc-feed::first-tick
                                select min(ts) from feed.tick where underlying = $1}, $symbol
    )->row_arrayrefs->as_list->retain;

    if (defined $first_insert->[0]) {
        $first_insert = $first_insert->[0] . "Z";
        $first_insert =~ s/ +/T/g;
    } else {
        $first_insert = Time::Moment->now->to_string;
    }
    my $earliest_db_entry = Time::Moment->from_string($first_insert)->at_midnight;
    $log->debugf('Earliest date available for %s is %s', $symbol, $earliest_db_entry->strftime('%Y-%m-%d'));

    # Again, we always handle in terms of full days - caller can override how much data we pull
    my ($start) = max_by {
        $_->epoch
    }
    $earliest_db_entry, $self->start_override // ();
    $self->_update_start_day($symbol, $start);

    return;
}

=head2 write_file

Called in order to write Ticks to file.

=over 4

=item * C<$symbol> - The symbol for the ticks to be writtern.

=item * C<$date> - The date of ticks to be written.

=item * C<$ticks> - Array ref of ticks to be written.

=back

=cut

sub write_file {
    my ($self, $symbol, $date, $ticks) = @_;

    my $filename = $self->sendfile->filename_for(
        underlying => $symbol,
        date       => $date,
    );
    my @non_zero = grep { $_ != 0 } @$ticks;

    $log->debugf('Number of elements in Ticks array: %d , date: %s, non-zero: %d, Symbol: %s', scalar @{$ticks}, $date, scalar @non_zero, $symbol);
    stats_gauge('local_feed.writer.number_of_ticks', scalar @non_zero, {tags => ['symbol:' . $symbol, 'date:' . $date->strftime('%Y-%m-%d')]});

    open my $fh, '>:raw', $filename or die("Unable to open file for wrinting $filename");
    $fh->print(pack '(N1)*', @{$ticks});
    close $fh;

    $log->debugf('File: %s is written', $filename);
    stats_inc('local_feed.files_written', {tags => ['symbol:' . $symbol, 'date:' . $date->strftime('%Y-%m-%d')]});
}

=head2 write_tick

Called in order to write a Tick to file.

=over 4

=item * C<$symbol> - The symbol for the ticks to be writtern.

=item * C<$tick> - The tick price that is going to be written.

=item * C<$index> - index of that tick in the day.

=item * C<$date> - date of the tick.

=back

=cut

sub write_tick {
    my ($self, $symbol, $date, $tick, $index) = @_;

    my $filename = $self->sendfile->filename_for(
        underlying => $symbol,
        date       => $date,
    );

    $log->debugf('Subscibed tick receives: %d , date: %s, index: %d, Symbol: %s', $tick, $date, $index, $symbol);
    stats_inc('local_feed.writer.subscribed_ticks', {tags => ['symbol:' . $symbol, 'date:' . $date->strftime('%Y-%m-%d')]});

    open my $fh, '+<:raw', $filename or die("Unable to open file for wrinting $filename");
    my $offset = $index * BYTES_PER_TICK;
    $fh->seek($offset, SEEK_SET);
    $fh->print(pack '(N1)*', $tick);
    close $fh;

    $log->debugf('File: %s is written', $filename);
    stats_inc('local_feed.files_written', {tags => ['symbol:' . $symbol, 'date:' . $date->strftime('%Y-%m-%d')]});
}

=head2 process_symbol

Can be considered to perform the main functionality. It get ticks from Database starting from a defined time, until it reaches the current day then it subscribes to redis and exits.

=over 4

=item * C<$symbol> - the symbol to process.

=back

=cut

async sub process_symbol {
    my ($self, $symbol) = @_;
    $log->debugf('Async process_symbol for %s', $symbol);
    my $underlying = Finance::Underlying->by_symbol($symbol)
        or die 'No underlying found for ' . $symbol;

    my $pip_size = $underlying->pip_size;
    my $feed     = $self->{feed};

    await $self->find_start($symbol);

    $log->debugf('Will populate data from %s', $self->start->{$symbol}->to_string);

    # Okay, we now have a starting point, and presume that we will process to the current epoch.
    # We'll need to start a subscription before we go any further: as ticks arrive from the feed
    # client, they can be folded into the pending data, and once we have fully populated the database
    # files we can write out the final day and continue processing as if that's what we wanted
    # to do all along.
    while (1) {
        my $today = Time::Moment->now;
        my $start = $self->start->{$symbol};
        my @ticks = (0) x (24 * 60 * 60);
        my $redis_subscription;

        # Is this batch for the current day? If so, let's start subscribing
        if ($today->at_midnight <= $start) {
            $redis_subscription = $redis_subscription // $self->subscribe_to_redis($symbol, $pip_size);
        }

        my $year  = $start->year;
        my $month = $start->month;

        $log->debugf('Querying');
        $log->debugf('Start: %s', $start->to_string);
        await $feed->query(
            q{-- rpc-feed::populate-tick-files
select ts, spot
from "feed".} . qq{"tick_${year}_${month}"} . q{
where ts >= $1::timestamp
and ts < $2::timestamp
and underlying = $3
order by ts
},
            $start->strftime('%Y-%m-%d'),
            $start->plus_days(1)->strftime('%Y-%m-%d'),
            $symbol,
            )->row_arrayrefs->each(
            sub {

                my $target = $_->[0];
                my $target_time;
                # Each entry is (ts, spot)
                $target .= 'Z';
                $target =~ s/ +/T/g;
                $target_time = Time::Moment->from_string($target);

                $ticks[$target_time->epoch - $start->epoch] = int floor(0.5 + ($_->[1] / $pip_size));
                $log->tracef(
                    'Adding to ticks array | symbol: %s, index: %d, value: %d',
                    $symbol,
                    ($target_time->epoch - $start->epoch),
                    int floor(0.5 + ($_->[1] / $pip_size)));

            })->completed;

        # Okay, we've pulled whatever's available from the database, and we've
        #skl subscribed and populated as well... did we end up with any gaps?

        # Write the entire day's worth of ticks out directly
        $self->write_file($symbol, $start, \@ticks);

        stats_timing(
            'local_feed.writer.query_elapsed_time',
            $today->delta_seconds(Time::Moment->now),
            {tags => ['symbol:' . $symbol, 'date:' . $start->strftime('%Y-%m-%d')]});

        # After subscribing to redis, there is no need to query Database further.
        @{$self->{ticks}->{$symbol}} = @ticks if $today->at_midnight <= $start;
        last if $today->at_midnight <= $start;
        # The whole day data has been written, now increment start
        $self->_update_start_day($symbol);
    }
}

=head1 METHODS - Accessors

=cut

sub db_connection_count { shift->{db_connection_count} }
sub feeddb_uri          { shift->{feeddb_uri} }
sub feed                { shift->{feed} }
sub start_override      { shift->{start_override} }
sub base_path           { shift->{base_path} }
sub sendfile            { shift->{sendfile} }
sub ticks               { shift->{ticks} }
sub start               { shift->{start} }
sub redis_source        { shift->{redis_source} }
sub symbols             { shift->{symbols} }

sub configure {
    my ($self, %args) = @_;
    for (qw(feeddb_uri db_connection_count start_override base_path redis_source symbols)) {
        $self->{$_} = delete $args{$_} if exists $args{$_};
    }

    return $self->next::method(%args);
}

sub send_stats {
    my ($self) = @_;
    my @symbols = @{$self->symbols};
    for (@symbols) {
        # Nothing is needed at the moment.
        # Update stats for every symbol.
    }
}

sub _add_to_loop {
    my ($self) = @_;
    $log->debugf('_add_to_loop invoked with feeddb_uri: %s AND db_connection_count: %d', $self->feeddb_uri, $self->db_connection_count);
    my $timer = IO::Async::Timer::Periodic->new(
        interval   => 5,
        reschedule => 'hard',
        on_tick    => $self->curry::weak::send_stats,
    );
    $timer->start;
    $self->add_child($timer);
    $self->add_child(
        $self->{feed} = Database::Async->new(
            uri  => $self->feeddb_uri,
            pool => {
                max => $self->db_connection_count,
            },
        ));

    $self->add_child(
        $self->{sendfile} = BOM::RPC::Feed::Sendfile->new(
            base_path => $self->base_path,
        ));

    # Accept epoch or date string, but always process full days
    if ($self->start_override) {
        if ($self->start_override =~ /^[0-9]+$/) {
            $self->{start_override} = Time::Moment->from_epoch($self->start_override)->at_midnight;
        } else {
            $self->{start_override} = Time::Moment->from_string($self->start_override)->at_midnight;
        }
    }

}

1;

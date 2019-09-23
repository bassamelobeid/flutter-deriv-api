package BOM::RPC::Feed::Tick;

use strict;
use warnings;

=head1 NAME

BOM::RPC::Feed::Tick - Class to get Ticks from as it handles communication between C<BOM::RPC::Feed::Reader>

=head1 DESCRIPTION

=cut

use Moo;

use IO::Async::Loop;
use IO::Async::Stream;
use Future::AsyncAwait;
use Log::Any qw($log);
use JSON::MaybeUTF8 qw(:v1);
use Time::Moment;
use Finance::Underlying;
use Postgres::FeedDB::Spot::Tick;

has [qw(loop connection stream)] => (
    is => 'ro',
);

has port => (
    is      => 'ro',
    default => 8006,
);

has symbol => (
    is       => 'rw',
    required => 1,
);

has [qw(start_time end_time limit)] => (
    is => 'rw',
);

sub BUILD {
    my $self = shift;

    $self->{loop}       = IO::Async::Loop->new;
    $self->{connection} = $self->{loop}->connect(
        addr => {
            family   => 'inet',
            socktype => "stream",
            port     => $self->port,
        },
    )->get;

    $self->{stream} = IO::Async::Stream->new(
        handle  => $self->connection,
        on_read => sub { },
    );
    $log->debugf('Connected to %s', join ':', map { $self->connection->$_ } qw(sockhost sockport));
    $self->{loop}->add($self->stream);
    return;

}

sub ticks_start_end_with_limit_for_charting {
    my ($self, $args) = @_;

    die 'start_time and end_time are required' unless $args->{start_time} && $args->{end_time};

    my $start_time = $args->{start_time} == 1 ? Time::Moment->now->minus_days(1) : Time::Moment->from_epoch($args->{start_time});
    my $end_time = $args->{end_time} eq 'latest' ? Time::Moment->now : Time::Moment->from_epoch($args->{end_time});
    my $limit = $args->{limit} // $self->limit;
    $limit = 0 if $limit > $start_time->delta_seconds($end_time);

    my @results;
    my $duration;
    while ($start_time->delta_days($end_time)) {
        $duration = $start_time->delta_seconds($start_time->plus_days(1)->at_midnight->minus_seconds(1));
        $duration = 1 unless $duration;
        push @results, $self->feed_reader($self->symbol, $start_time->epoch, $duration)->get;
        $start_time = $start_time->plus_days(1)->at_midnight;
    }
    $duration = $start_time->delta_seconds($end_time) + 1;
    push @results, $self->feed_reader($self->symbol, $start_time->epoch, $duration)->get if $duration;
    @results = @results[(scalar @results - $limit) .. (scalar @results - 1)] if $limit && $limit < scalar @results;
    return \@results;
}

async sub feed_reader {
    my ($self, $symbol, $start, $duration) = @_;

    my $underlying = Finance::Underlying->by_symbol($symbol) or die 'No underlying found for ' . $symbol;
    my $pip_size = $underlying->pip_size or die 'invalid pip size for ' . $symbol;

    $log->debugf('Request from %d duration %d for %s', $start, $duration, $symbol);
    await $self->stream->write(
        pack 'N/a*',
        encode_json_utf8({
                underlying => $symbol,
                start      => $start,
                duration   => $duration,
            }));
    my $read = await $self->stream->read_exactly(4);
    die "no return, check reader logs.\n" unless $read;
    my ($size) = unpack 'N1' => $read;
    $log->debugf('Expect %d bytes', $size);
    die 'way too much data' if $size > 4 * $duration;
    my $data      = await $self->stream->read_exactly($size);
    my @ticks     = unpack "(N1)*", $data;
    my $base_time = Time::Moment->from_epoch($start);
    my @results;

    for my $idx (0 .. $duration - 1) {
        my $tick = $ticks[$idx] or next;
        # multiply with pip_size to bring back original price
        # use pipsized_value to make sure price formatted.
        $tick = $underlying->pipsized_value($tick * $pip_size);
        my $tick_proc = Postgres::FeedDB::Spot::Tick->new({
            symbol => $symbol,
            epoch  => $base_time->plus_seconds($idx)->epoch,
            quote  => $tick,
            bid    => $tick,
            ask    => $tick,
        });
        push @results, $tick_proc;
    }
    return @results;
}

1;

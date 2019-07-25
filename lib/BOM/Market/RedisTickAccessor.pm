package BOM::Market::RedisTickAccessor;

use strict;
use warnings;

use Moo;

use Carp qw(confess);
use BOM::Market::DataDecimate;

use Postgres::FeedDB::Spot::Tick;

=head1 NAME
BOM::Market::RedisTickAccessor - provides the same API (as Quant::Framework::Underlying) to access feed related data using using redis as source.
=cut

has underlying => (
    is       => 'ro',
    required => 1,
);

has _tick_source => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_tick_source'
);

sub _build_tick_source {
    return BOM::Market::DataDecimate->new;
}

=head2 tick_at
Returns consistent tick<Postgres::FeedDB::Spot::Tick> at the specified epoch:
->tick_at(time);
If tick consistency is not important to you (could.'t think of why):
->tick_at(time, {allow_inconsistent => 1});

Definition of consistent tick. Current system expects 1 tick every second. So, to ensure ticks are consistent we have the following rules:
- if there's a tick at the requested time, the tick is returned as there will not be another tick at the requested second.

- if there's a tick before the requested time, there are two outcomes:

(a) the tick for the requested second hasn't arrived.
(b) there's no tick for the requested second.

To determine if it is (a) or (b), we wait for next tick.
=cut

sub tick_at {
    my ($self, $epoch, $args) = @_;

    confess 'epoch is required' unless $epoch;

    if ($args and $args->{allow_inconsistent}) {
        my ($tick) = @{
            $self->ticks_in_between_end_limit({
                    end_time => $epoch,
                    limit    => 1
                })};
        return $tick;
    }

    my ($tick) = @{
        $self->ticks_in_between_start_limit({
                start_time => $epoch,
                limit      => 1,
            })};

    return undef unless ($tick);

    return $tick if $tick->epoch == $epoch;

    my ($previous_tick) = @{
        $self->ticks_in_between_end_limit({
                end_time => $epoch,
                limit    => 1
            })};

    return $previous_tick;
}

=head2 spot_tick
Returns the current tick.
=cut

sub spot_tick {
    my $self = shift;

    return $self->tick_at(time, {allow_inconsistent => 1});
}

=head2 next_tick_after

Returns a L<tick|Postgres::FeedDB::Spot::Tick> after the specified epoch.

=cut

sub next_tick_after {
    my ($self, $epoch) = @_;

    confess 'epoch is required' unless $epoch;

    my ($next_tick) = @{
        $self->ticks_in_between_start_limit({
                start_time => $epoch + 1,
                limit      => 1
            })};

    return $next_tick;
}

=head2 ticks_in_between_end_limit
Returns the nth number of ticks<Postgres::FeedDB::Spot::Tick> (specified by limit) at or before the end_time
->ticks_in_between_end_limit({
    end_time => time,
    limit => 10
});
=cut

sub ticks_in_between_end_limit {
    my ($self, $args) = @_;

    confess 'end_time is required' unless $args->{end_time};
    confess 'limit is required' unless exists $args->{limit};
    my $ticks = $self->_tick_source->tick_cache_get_num_ticks({
        underlying => $self->underlying,
        end_epoch  => $args->{end_time},
        num        => $args->{limit},
    });

    $ticks = [reverse @$ticks];

    return $self->_wrap_as_tick_object($ticks);
}

=head2 ticks_in_between_start_limit
Returns the nth number of ticks<Postgres::FeedDB::Spot::Tick> (specified by limit) at or after the start_time
->ticks_in_between_start_limit({
    start_time => time,
    limit => 10
});
=cut

sub ticks_in_between_start_limit {
    my ($self, $args) = @_;

    confess 'start_time is required' unless $args->{start_time};
    confess 'limit is required' unless exists $args->{limit};
    my $ticks = $self->_tick_source->tick_cache_get_num_ticks({
        underlying  => $self->underlying,
        start_epoch => $args->{start_time},
        num         => $args->{limit},
    });

    return $self->_wrap_as_tick_object($ticks);
}

=head2 ticks_in_between_start_end
Returns all the ticks between start_time and end_time.
->ticks_in_between_start_end(
    start_time => time,
    end_time => time + 300
);
=cut

sub ticks_in_between_start_end {
    my ($self, $args) = @_;

    confess 'start_time is required' unless $args->{start_time};
    confess 'end_time is required'   unless $args->{end_time};
    confess 'end_time is before start_time' if $args->{end_time} < $args->{start_time};

    my $ticks = $self->_tick_source->tick_cache_get({
        underlying  => $self->underlying,
        start_epoch => $args->{start_time},
        end_epoch   => $args->{end_time},
    });

    $ticks = [reverse @$ticks];

    return $self->_wrap_as_tick_object($ticks);
}

=head2 has_cache

Checks if we have cache for this specific symbol at a specific time.

=cut

sub has_cache {
    my ($self, $epoch) = @_;

    my $key = $self->_tick_source->_make_key($self->underlying->symbol, 0);

    return $self->_tick_source->redis_read->zcount($key, $epoch, $epoch + 10);
}

sub cache_retention_interval {
    my $self = shift;
    return $self->_tick_source->raw_retention_interval;
}

sub _wrap_as_tick_object {
    my ($self, $ticks) = @_;

    my $symbol = $self->underlying->symbol;
    return [map { Postgres::FeedDB::Spot::Tick->new(+{%$_, symbol => $symbol}) } @$ticks];
}

1;

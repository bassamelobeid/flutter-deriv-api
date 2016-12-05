package BOM::Market::DataResample;

=head1 NAME

BOM::Market::DataResample

=head1 SYNOPSYS

    use BOM::Market::DataResample;

=head1 DESCRIPTION

A wrapper to let us use Redis SortedSets to get aggregated tick data.

=cut

use 5.010;
use Moose;

use List::Util qw( first min max );
use Quant::Framework::Underlying;
use BOM::System::RedisReplicated;
use BOM::Market::ResampleCache;

has resample_cache => (
    is      => 'ro',
    default => sub {
        BOM::Market::ResampleCache->new;
    },
);

sub get {
    my ($self, $args) = @_;

    my $resample_flag = $args->{resample} // 1;

    my $ticks;
    if ($resample_flag) {
        $ticks = $self->resample_cache_get($args);
    } else {
        $ticks = $self->tick_cache_get($args);
    }
    return $ticks;
}

sub resample_cache_get {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $start_time = $args->{start_epoch};
    my $end_time   = $args->{end_epoch};
    my $backtest   = $args->{backtest} // 0;

    my $ticks;
    if ($backtest) {
        my $start = $end_time - min($end_time - $start_time, $self->resample_cache->resample_retention_interval->seconds);
        $start = $start - $start % $self->resample_cache->sampling_frequency->seconds;
        my $first_agg = $start - $self->resample_cache->sampling_frequency->seconds;

        my $raw_ticks = $underlying->ticks_in_between_start_end({
            start_time => $first_agg,
            end_time   => $end_time,
        });

        my @rev_ticks = reverse @$raw_ticks;
        $ticks = $self->resample_cache->resample_cache_backfill({
                symbol   => $underlying->symbol,
                data     => \@rev_ticks,
                backtest => $backtest,
            }) if ($raw_ticks);
    } else {
        $ticks = $self->resample_cache->resample_cache_get({
            symbol      => $underlying->symbol,
            start_epoch => $start_time,
            end_epoch   => $end_time,
        });
    }
    return $ticks;
}

sub tick_cache_get {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $start_time = $args->{start_epoch};
    my $end_time   = $args->{end_epoch};
    my $backtest   = $args->{backtest} // 0;

    my $ticks;
    if ($backtest) {
        my $start = $end_time - min($end_time - $start_time, $self->resample_cache->resample_retention_interval->seconds);
        $start = $start - $start % $self->resample_cache->sampling_frequency->seconds;
        my $first_agg = $start - $self->resample_cache->sampling_frequency->seconds;

        my $raw_ticks = $underlying->ticks_in_between_start_end({
            start_time => $first_agg,
            end_time   => $end_time,
        });
        my @rev_ticks = reverse @$raw_ticks;
        $ticks = \@rev_ticks;
    } else {
        $ticks = $self->resample_cache->data_cache_get({
            symbol      => $underlying->symbol,
            start_epoch => $start_time,
            end_epoch   => $end_time,
        });
    }

    return $ticks;
}

sub tick_cache_get_num_ticks {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $num        = $args->{num};
    my $end_time   = $args->{end_epoch};

    my $ticks = $self->resample_cache->data_cache_get_num_data({
        symbol    => $underlying->symbol,
        end_epoch => $end_time,
        num       => $num,
    });

    return $ticks;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

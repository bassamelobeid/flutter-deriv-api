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

use Quant::Framework::Underlying;
use BOM::System::RedisReplicated;
use BOM::Market::ResampleCache;

has resample_cache => (
    is      => 'ro',
    default => sub {
        BOM::Market::ResampleCache->new;
    },
);

sub resample_or_raw {
    my ($self, $args) = @_;

    my $resample_flag = $args->{resample} // 1;

    my $ticks;
    if ($resample_flag) {
        $ticks = $self->resample_cache_get($args);
    } else {
        $ticks = $self->tick_cache_get($args);
    }
}

sub resample_cache_get {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $start_time = $args->{start_epoch};
    my $end_time   = $args->{end_epoch};
    my $backtest   = $args->{backtest} // 0;

    my $ticks;
    if ($backtest) {
        my $raw_ticks = $underlying->ticks_in_between_start_end({
            start_time => $start_time,
            end_time   => $end_time,
        });

        my @rev_ticks = reverse @$raw_ticks;
        $ticks = $self->resample_cache->resample_cache_backfill({
            symbol   => $underlying->symbol,
            data     => \@rev_ticks,
            backtest => $backtest,
        });
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
        my $ticks = $underlying->ticks_in_between_start_end({
            start_time => $start_time,
            end_time   => $end_time,
        });
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

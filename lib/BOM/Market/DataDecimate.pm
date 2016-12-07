package BOM::Market::DataDecimate;

=head1 NAME

BOM::Market::DataDecimate

=head1 SYNOPSYS

    use BOM::Market::DataDecimate;

=head1 DESCRIPTION

A wrapper to let us use Redis to get decimated tick data.

=cut

use 5.010;
use Moose;

use List::Util qw( first min max );
use Quant::Framework::Underlying;
use BOM::System::RedisReplicated;
use BOM::Market::DecimateCache;

has decimate_cache => (
    is      => 'ro',
    default => sub {
        BOM::Market::DecimateCache->new;
    },
);

sub get {
    my ($self, $args) = @_;

    my $decimate_flag = $args->{decimate} // 1;

    my $ticks;
    if ($decimate_flag) {
        $ticks = $self->decimate_cache_get($args);
    } else {
        $ticks = $self->tick_cache_get($args);
    }
    return $ticks;
}

sub decimate_cache_get {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $start_time = $args->{start_epoch};
    my $end_time   = $args->{end_epoch};
    my $backtest   = $args->{backtest} // 0;

    my $ticks;
    if ($backtest) {
        my $start = $end_time - min($end_time - $start_time, $self->decimate_cache->decimate_retention_interval->seconds);
        $start = $start - $start % $self->decimate_cache->sampling_frequency->seconds;
        my $first_agg = $start - $self->decimate_cache->sampling_frequency->seconds;

        my $raw_ticks = $underlying->ticks_in_between_start_end({
            start_time => $first_agg,
            end_time   => $end_time,
        });

        my @rev_ticks = reverse @$raw_ticks;
        $ticks = $self->decimate_cache->data_decimate->decimate({
            data => \@rev_ticks,
        });
    } else {
        $ticks = $self->decimate_cache->decimate_cache_get({
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
        my $raw_ticks = $underlying->ticks_in_between_start_end({
            start_time => $start_time,
            end_time   => $end_time,
        });
        my @rev_ticks = reverse @$raw_ticks;
        $ticks = \@rev_ticks;
    } else {
        $ticks = $self->decimate_cache->data_cache_get({
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

    my $ticks = $self->decimate_cache->data_cache_get_num_data({
        symbol    => $underlying->symbol,
        end_epoch => $end_time,
        num       => $num,
    });

    return $ticks;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

package BOM::Product::Pricing::Parameter;

use strict;
use warnings;

use List::Util qw(sum);
use BOM::Market::AggTicks;

use base qw( Exporter );
our @EXPORT_OK = qw(get_parameter);

my $allow_methods = {
    vol_proxy   => \&vol_proxy,
    trend_proxy => \&trend_proxy,
};

sub get_parameter {
    my ($name, $args) = @_;
    return $allow_methods->{$name}->($args);
}

sub vol_proxy {
    my $args = shift;

    my $err;
    my $underlying   = $args->{underlying};
    my $date_pricing = $args->{date_pricing};

    my $ticks = BOM::Market::AggTicks->new->retrieve({
        underlying   => $underlying,
        ending_epoch => $date_pricing->epoch,
        tick_count   => 20,
    });

    my @latest = @$ticks;
    my $vol_proxy;
    if (@latest and @latest == 20 and abs($date_pricing->epoch - $latest[0]->{epoch}) < 300) {
        my $sum = sum(map { log($latest[$_]->{quote} / $latest[$_ - 1]->{quote})**2 } (1 .. 19));
        $vol_proxy = sqrt($sum / 19);
    } else {
        $vol_proxy = 0.20;                                                 # 20% volatility
        $err       = 'Do not have enough ticks to calculate volatility';
    }

    return {
        value => $vol_proxy,
        error => $err,
    };
}

sub trend_proxy {
    my $args = shift;

    my $err;
    # trend proxy calculation depends on vol proxy
    my $vol_proxy_reference = vol_proxy($args);
    my $trend_proxy;
    if (not $vol_proxy_reference->{error}) {
        my $latest = BOM::Market::AggTicks->new->retrieve({
            underlying   => $args->{underlying},
            ending_epoch => $args->{date_pricing}->epoch,
            tick_count   => 20,
        });
        my $ma_step = 7;
        my $avg     = sum(map { $_->{quote} } @$latest[-$ma_step .. -1]) / $ma_step;
        my $x       = ($latest->[-1]{quote} - $avg) / $latest->[-1]{quote};
        $trend_proxy = $x / $vol_proxy_reference->{value};
    } else {
        $trend_proxy = 0;                               # no trend
        $err         = $vol_proxy_reference->{error};
    }

    return {
        value => $trend_proxy,
        error => $err,
    };
}

1;

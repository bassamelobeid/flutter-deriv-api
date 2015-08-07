package BOM::WebSocketAPI::Symbols;

use strict;
use warnings;

use Mojo::Base 'BOM::WebSocketAPI::BaseController';

sub _ticks {
    my (%args) = @_;
    my $ul    = $args{ul} || die 'no underlying';
    my $start = $args{start};
    my $end   = $args{end};
    my $count = $args{count};

    # we must not return to the client any ticks after this epoch
    my $licensed_epoch = $ul->last_licensed_display_epoch;
    my $when = DateTime->from_epoch(epoch => $licensed_epoch);

    unless ($start
        and $start =~ /^[0-9]+$/
        and $start > time - 365 * 86400
        and $start < $licensed_epoch)
    {
        $start = $licensed_epoch - 86400;
    }
    unless ($end
        and $end =~ /^[0-9]+$/
        and $end > $start
        and $end <= $licensed_epoch)
    {
        $end = $licensed_epoch;
    }
    unless ($count
        and $count =~ /^[0-9]+$/
        and $count > 0
        and $count < 5000)
    {
        $count = 500;
    }
    my $ticks = $ul->feed_api->ticks_start_end_with_limit_for_charting({
        start_time => $start,
        end_time   => $end,
        limit      => $count,
    });

    return [map { {time => $_->epoch, price => $_->quote} } reverse @$ticks];
}


1;

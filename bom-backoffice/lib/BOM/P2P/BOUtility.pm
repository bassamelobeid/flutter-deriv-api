package BOM::P2P::BOUtility;

use strict;
use warnings;
use Date::Utility;
use JSON::MaybeUTF8 qw(:v1);

=head2 format_schedule

Decodes and formats the json p2p advertiser schedule returned from db functions.

=cut

sub format_schedule {
    my $schedule = shift;
    my $offset   = shift // 0;    # seconds

    $schedule = decode_json_utf8($schedule);
    my $d = Date::Utility->new('2024-04-07 00:00:00GMT');    # a random Sunday

    my %schedule_days;
    for my $period (@$schedule) {
        my $start = $d->plus_time_interval(($period->[0] // 0) . 'm')->plus_time_interval($offset . 's');
        my $end   = $d->plus_time_interval(($period->[1] // 10080) . 'm')->plus_time_interval($offset . 's');

        my $start_day = $start->days_between($d);
        my $end_day   = $end->minus_time_interval('1m')->days_between($d);    # e.g. minute 10080 should end on sat not sun

        for my $day ($start_day .. $end_day) {
            my $day_start = $day == $start_day ? $start : $d->plus_time_interval($day . 'd')->truncate_to_day;
            my $day_end   = $day == $end_day   ? $end   : $d->plus_time_interval(($day + 1) . 'd')->truncate_to_day;
            push $schedule_days{$day % 7}->@*, [$day_start, $day_end];
        }
    }

    my @res;
    for my $day (0 .. 6) {
        my $item = [$d->plus_time_interval($day . 'd')->full_day_name, 'not available'];

        if ($schedule_days{$day}) {
            my @periods = sort { $a->[0]->time_hhmm =~ s/://gr <=> $b->[0]->time_hhmm =~ s/://gr } $schedule_days{$day}->@*;

            # merge neighbouring periods
            for (my $idx = 1;; $idx++) {
                last if $idx > $#periods;
                if ($periods[$idx - 1][1]->time_hhmm eq $periods[$idx][0]->time_hhmm) {
                    $periods[$idx - 1][1] = $periods[$idx][1];    # set end of previous period to the end of this one
                    splice @periods, $idx, 1;                     # delete this period
                    redo;                                         # repeat loop for the same $idx value
                }
            }

            $item->[1] = join ', ', map { $_->[0]->time_hhmm . ' - ' . $_->[1]->minus_time_interval('1m')->time_hhmm } @periods;
        }

        push @res, $item;
    }

    return \@res;
}

1;

#!/etc/rmg/bin/perl -w

package BOM::Market::Script::TickAgg;

use Moose;
with 'App::Base::Daemon';

use List::Util qw(max);
use Parallel::ForkManager;
use Time::HiRes qw(time sleep);

use BOM::Market::AggTicks;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData qw(create_underlying_db);

sub documentation {
    return qq/This daemon aggregates ticks into redis for short-term pricing./;
}

sub daemon_run {
    my $self = shift;

    my $at = BOM::Market::AggTicks->new;
    my @uls = map { create_underlying($_) } create_underlying_db->symbols_for_intraday_fx;

    my $pm = Parallel::ForkManager->new(scalar @uls);    # We'll run one process for each underlying, unless that proves fatal in some way.
    $pm->run_on_finish(
        sub {
            my ($pid, $exit_code, $ident_symbol, $exit_signal, $core_dump, $data_structure_reference) = @_;

            if (defined($data_structure_reference)) {    # children are not forced to send anything
                my ($count, $first, $last) = @$data_structure_reference;
                warn('No back-fill aggregations for ' . $ident_symbol) unless $count;
            } else {
                warn('Error in loading of ' . $ident_symbol . ' exit code: ' . $exit_code);
            }
        });

    foreach my $ul (@uls) {
        $pm->start($ul->symbol) and next;
        my ($count, $first, $last) = $at->fill_from_historical_feed({
            underlying => $ul,
        });
        $pm->finish(0, [$count, $first, $last]);
    }
    $pm->wait_all_children;
    undef $pm;

    my $now        = int time;
    my $hold_time  = 1;                                          # Wait 1 second for ticks to make it into the cache;
    my $ai         = $at->agg_interval->seconds;
    my $next_start = $now - ($now % $ai) + ($ai + $hold_time);

    while (1) {
        my $sleep = max(0, $next_start - time);
        sleep($sleep);
        my $fill_poch = $next_start - $hold_time;
        $next_start += $ai;

        foreach my $ul (@uls) {
            $at->check_delay($ul);
            $at->aggregate_for({
                underlying => $ul,
                epoch      => $fill_poch,
            });
        }
    }
}

sub handle_shutdown {
    my $self = shift;
    warn('Shutting down; may cause incorrect short-term pricing.');
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

package main;
use strict;

exit BOM::Market::Script::TickAgg->new({
        user  => 'nobody',
        group => 'nogroup',
    })->run;

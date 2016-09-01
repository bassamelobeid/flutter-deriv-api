#!/usr/bin/perl
package BOM::Market::Script::MonitorTickAgg;

use Moose;
with 'App::Base::Daemon';

use BOM::Market::UnderlyingDB;
use BOM::Market::Underlying;
use BOM::Market::AggTicks;
use BOM::System::Chronicle;

use Quant::Framework::TradingCalendar;
use Date::Utility;
use Time::Duration::Concise;
use Time::HiRes;
use List::Util qw(max);
use List::MoreUtils qw(uniq);

sub documentation {
    return
        'This daemon checks the quality of the aggregated ticks in redis once every 2 minutes. It cleans and repoulate aggregated tick data if it finds any data corruption.';
}

sub daemon_run {
    my $self = shift;

    my @underlyings = map { BOM::Market::Underlying->new($_) } BOM::Market::UnderlyingDB->instance->symbols_for_intraday_fx;
    my $lookback_interval = Time::Duration::Concise->new(interval => '5h');
    my $at = BOM::Market::AggTicks->new;

    while (1) {
        # checks status of aggregated ticks every 2 minutes.
        my $next_start = Time::HiRes::time + 120;
        my @corrupted_pairs;
        my $now = Date::Utility->new;
        warn('Checking aggregated ticks status at ' . $now->datetime);
        # since we only aggregated ticks for Forex for now, we don't need to know about the trading days
        # of other exchanges.
        my $previous_day_a_trading_day = Quant::Framework::TradingCalendar->new({
                symbol           => 'FOREX',
                chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            })->trades_on($now->minus_time_interval('1d'));

        foreach my $u (@underlyings) {
            my $ticks = $at->retrieve({
                underlying   => $u,
                ending_epoch => $now->epoch,
                interval     => $lookback_interval,
            });
            my @uniq_epoch = uniq map { $_->{epoch} } @$ticks;
            # 4 intervals per minute because we sample every 15 seconds.
            # frxAUDPLN is an exception here. It ticks every minute or sometimes 1 1/2 minute.
            # If we have less that 80% good ticks, we will scrap and repopulate.
            my $expected_interval_per_minute = $u->symbol eq 'frxAUDPLN' ? 1 : 4;
            if ((
                       $previous_day_a_trading_day
                    or $now->hour + 0 > 5
                )
                and @uniq_epoch < 0.8 * (($lookback_interval->minutes * $expected_interval_per_minute) + 1))
            {
                warn(     '['
                        . $u->symbol
                        . '] expected '
                        . (($lookback_interval->minutes * 4) + 1)
                        . ' ticks retrieved '
                        . scalar(@$ticks)
                        . ' uniq ticks '
                        . scalar(@uniq_epoch));
                push @corrupted_pairs, $u->symbol;
            }
        }

        if (@corrupted_pairs) {
            if (`ps -aef | grep -v grep | grep tickagg`) {
                system("sudo service binary_tickagg stop");
                sleep(1);    # just to give 1 second for tickagg to stop.
            }
            warn("Flushing $_") and $at->flush($_) foreach @corrupted_pairs;
            system("sudo service binary_tickagg start");
        }

        warn('Checks complete [' . Date::Utility->new->datetime . '].');

        my $wait_seconds = max(0, $next_start - Time::HiRes::time);
        Time::HiRes::sleep($wait_seconds);
    }
    return 1;
}

sub handle_shutdown {
    my $self = shift;
    warn('Shutting down.');
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

package main;
use strict;

exit BOM::Market::Script::MonitorTickAgg->new({
        user  => 'nobody',
        group => 'nogroup',
    })->run;

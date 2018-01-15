package BOM::Product::Script::MondayCommission;

use strict;
use warnings;

use Date::Utility;
use LandingCompany::Registry;
use Quant::Framework;
use Finance::Exchange;

use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;
use BOM::Platform::Runtime;

sub run {
    # a cron to sunday every Sunday at 00:30:00 to update commission on the next trading day.
    my $now              = Date::Utility->new;
    my $next_trading_day = _next_trading_day($now);

    return unless $next_trading_day;

    my $to_day               = $next_trading_day->truncate_to_day;
    my $twenty_minutes_later = $to_day->plus_time_interval('20m');
    my @underlying_symbols   = LandingCompany::Registry::get('japan')->multi_barrier_offerings(BOM::Platform::Runtime->instance->get_offerings_config)
        ->values_for_key('underlying_symbol');
    my $quants_config = BOM::Platform::QuantsConfig->new(
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        recorded_date    => $now,
    );

    foreach my $symbol (@underlying_symbols) {
        $quants_config->save_config(
            'commission',
            +{
                name              => "monday morning commission for $symbol",
                underlying_symbol => $symbol,
                start_time        => $to_day->epoch,
                end_time          => $twenty_minutes_later->epoch,
                partitions        => [{
                        partition_range => '0-0.5',
                        flat            => 0,
                        cap_rate        => 0.1,
                        floor_rate      => 0.01,
                        width           => 0.5,
                        centre_offset   => 0,
                    }
                ],
            });
    }

    return;
}

sub _next_trading_day {
    my $date = shift;

    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader());
    my $exchange         = Finance::Exchange->create_exchange('FOREX');
    for (1 .. 5) {
        my $next_day = $date->plus_time_interval('1d');
        if ($trading_calendar->trades_on($exchange, $next_day)) {
            return $next_day;
        }
        $date = $next_day;
    }

    warn "Cannot find a trading day for " . $exchange->symbol . " from " . Date::Utility->new->date . " to " . $date->datetime;

    return;
}

1;

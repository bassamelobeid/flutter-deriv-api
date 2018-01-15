package BOM::Product::Script::MondayCommission;

use strict;
use warnings;

use Date::Utility;
use LandingCompany::Registry;

use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;
use BOM::Platform::Runtime;

sub run {
    # a cron to sunday every Sunday to update commission on Monday mornings.
    my $now                  = Date::Utility->new;
    my $monday               = $now->plus_time_interval('1d')->truncate_to_day;
    my $twenty_minutes_later = $monday->plus_time_interval('20m');
    my @underlying_symbols   = LandingCompany::Registry::get('japan')->multi_barrier_offerings(BOM::Platform::Runtime->instance->get_offerings_config)
        ->values_for_key('underlying_symbol');
    my $quants_config = BOM::Platform::QuantsConfig->new(
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
        recorded_date    => $now,
    );
    foreach my $symbol (@underlying_symbols) {
        $quants_config->save_config(
            'commission',
            +{
                name              => "monday morning commission for $symbol",
                underlying_symbol => $symbol,
                start_time        => $monday->epoch,
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

1;

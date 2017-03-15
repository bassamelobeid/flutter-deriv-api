package GenerateTradingPeriods;
use strict;
use warnings;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods next_generation_epoch);
use Parallel::ForkManager;
use Time::HiRes qw(clock_nanosleep TIMER_ABSTIME CLOCK_REALTIME);
use Date::Utility;

#This daemon generates predefined trading periods for selected underlying symbols at XX:45 and XX:00

sub run {
    my @selected_symbols = BOM::Product::Contract::PredefinedParameters::supported_symbols;
    my $fm               = Parallel::ForkManager->new(scalar(@selected_symbols));

    while (1) {
        foreach my $symbol (@selected_symbols) {
            $fm->start and next;
            generate_trading_periods($symbol);
            $fm->finish;
        }
        $fm->wait_all_children;

        my $next = next_generation_epoch(Date::Utility->new);

        clock_nanosleep(CLOCK_REALTIME, $next * 1e9, TIMER_ABSTIME);
    }
}

1;

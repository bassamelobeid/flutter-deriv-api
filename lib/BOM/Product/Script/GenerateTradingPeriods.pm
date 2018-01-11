package BOM::Product::Script::GenerateTradingPeriods;
use strict;
use warnings;

use LandingCompany::Registry;
use BOM::Product::ContractFinder;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods next_generation_epoch generate_barriers_for_window);
use BOM::Platform::Runtime;
use Time::HiRes qw(clock_nanosleep TIMER_ABSTIME CLOCK_REALTIME);
use Date::Utility;
use List::Util qw(max min);
use Scalar::Util qw(looks_like_number);
use Parallel::ForkManager;

#This daemon generates predefined trading periods for selected underlying symbols at every hour

sub run {

    my $offerings_obj    = LandingCompany::Registry::get('japan')->multi_barrier_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
    my @selected_symbols = $offerings_obj->values_for_key('underlying_symbol');
    my $chronicle_writer = BOM::Platform::Chronicle::get_chronicle_writer();
    my $finder           = BOM::Product::ContractFinder->new;
    my $cpu_info         = `/usr/bin/env nproc`;
    chomp $cpu_info;
    $cpu_info = looks_like_number($cpu_info) ? $cpu_info / 2 : 4;    # we should have 4 cores?
    my $processes = min($cpu_info, scalar @selected_symbols);
    my $fm = Parallel::ForkManager->new($processes);

    while (1) {
        my $now  = Date::Utility->new;
        my $next = next_generation_epoch($now);

        foreach my $symbol (@selected_symbols) {
            $fm->start and next;
            my $tp = generate_trading_periods($symbol, $now);
            next unless @$tp;
            my ($tp_namespace, $tp_key) = BOM::Product::Contract::PredefinedParameters::trading_period_key($symbol, $now);
            my $ttl = max(1, $next - $now->epoch);
            # 1 - to save to chronicle database
            $chronicle_writer->set($tp_namespace, $tp_key, [grep { defined } @$tp], $now, 1, $ttl);

            # generate predefined barriers for a specific trading window
            foreach my $trading_period (@$tp) {
                my $barriers = generate_barriers_for_window($symbol, $trading_period);
                # for barriers that's already generated, skip them here.
                next unless $barriers;
                my ($barrier_namespace, $barrier_key) =
                    BOM::Product::Contract::PredefinedParameters::predefined_barriers_key($symbol, $trading_period);
                my $ttl = max(1, $trading_period->{date_expiry}->{epoch} - $trading_period->{date_start}->{epoch});
                $chronicle_writer->set($barrier_namespace, $barrier_key, $barriers, $now, 1, $ttl);
            }

            # store by contract category expiry and barriers.
            my ($category_namespace, $category_key) = BOM::Product::Contract::PredefinedParameters::barrier_by_category_key($symbol);
            my $by_category = $finder->multi_barrier_contracts_by_category_for({symbol => $symbol});
            $chronicle_writer->set($category_namespace, $category_key, $by_category, $now, 1, $ttl);
            $fm->finish;
        }
        $fm->wait_all_children;

        clock_nanosleep(CLOCK_REALTIME, $next * 1e9, TIMER_ABSTIME);
    }
    return;
}

1;

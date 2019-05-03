package BOM::Product::Script::GenerateTradingPeriods;
use strict;
use warnings;

use LandingCompany::Registry;
use BOM::Product::ContractFinder;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods next_generation_epoch generate_barriers_for_window);
use BOM::Config::Runtime;
use Time::HiRes qw(clock_nanosleep TIMER_ABSTIME CLOCK_REALTIME);
use Date::Utility;
use POSIX qw(ceil);
use List::Util qw(max min);
use Sys::Info;
use Parallel::ForkManager;
use Quant::Framework;
use BOM::Config::Chronicle;

#This daemon generates predefined trading periods for selected underlying symbols at every hour

my $next_generation_time;

sub _set_next_generation_time {
    $next_generation_time = shift;
    return;
}

sub run {

    my $offerings_obj    = LandingCompany::Registry::get('svg')->multi_barrier_offerings(BOM::Config::Runtime->instance->get_offerings_config);
    my @selected_symbols = $offerings_obj->values_for_key('underlying_symbol');
    my $chronicle_writer = BOM::Config::Chronicle::get_chronicle_writer();
    my $finder           = BOM::Product::ContractFinder->new;
    my $cpu_count        = Sys::Info->new->device("CPU")->count || 4;
    my $processes        = min(ceil($cpu_count / 2), 0 + @selected_symbols);
    my $fm               = Parallel::ForkManager->new($processes);

    $fm->run_on_start(
        sub {
            my ($pid, $ident) = @_;
        });

    $fm->run_on_finish(
        sub {
            my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $data) = @_;
            if (defined $data and $data->{next_generation_time}) {
                warn "Failed to generate trading windows. Setting next generation time to "
                    . Date::Utility->new($data->{next_generation_time})->datetime;
                _set_next_generation_time($data->{next_generation_time});
            }
        });

    my $exchange = Finance::Exchange->create_exchange('FOREX');

    while (1) {
        my $now = Date::Utility->new;

        my $trading_day = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader())->trades_on($exchange, $now);
        _set_next_generation_time(next_generation_epoch($now));

        foreach my $symbol (@selected_symbols) {
            $fm->start($symbol) and next;
            my $tp = generate_trading_periods($symbol, $now);

            # don't use next here as it would cause it would spawn another child
            unless (@$tp) {
                # if we are not getting any trading period generated, chances are barrier calculation
                # will fail. Retry again 2-second later
                my %next = $trading_day ? (next_generation_time => $now->plus_time_interval('2s')->epoch) : ();
                $fm->finish(0, \%next);
            }

            my ($tp_namespace, $tp_key) = BOM::Product::Contract::PredefinedParameters::trading_period_key($symbol, $now);
            my $ttl = max(1, $next_generation_time - $now->epoch);
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

        clock_nanosleep(CLOCK_REALTIME, $next_generation_time * 1e9, TIMER_ABSTIME);
    }
    return;
}

1;

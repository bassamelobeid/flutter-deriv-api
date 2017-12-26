package BOM::Product::Script::GenerateTradingPeriods;
use strict;
use warnings;

use LandingCompany::Registry;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods next_generation_epoch);
use BOM::Platform::Runtime;
use Time::HiRes qw(clock_nanosleep TIMER_ABSTIME CLOCK_REALTIME);
use Date::Utility;
use List::Util qw(max);

#This daemon generates predefined trading periods for selected underlying symbols at every hour

sub run {

    my $offerings_obj    = LandingCompany::Registry::get('japan')->multi_barrier_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
    my @selected_symbols = $offerings_obj->values_for_key('underlying_symbol');

    while (1) {
        my $now  = Date::Utility->new;
        my $next = next_generation_epoch($now);

        foreach my $symbol (@selected_symbols) {
            my $tp = generate_trading_periods($symbol, $now);
            next unless @$tp;
            my @redis_key = BOM::Product::Contract::PredefinedParameters::trading_period_key($symbol, $now);
            my $ttl = max(1, $next - $now->epoch);
            # 1 - to save to chronicle database
            BOM::Platform::Chronicle::get_chronicle_writer()->set(@redis_key, [grep { defined } @$tp], $now, 1, $ttl);
        }

        clock_nanosleep(CLOCK_REALTIME, $next * 1e9, TIMER_ABSTIME);
    }
    return;
}

1;

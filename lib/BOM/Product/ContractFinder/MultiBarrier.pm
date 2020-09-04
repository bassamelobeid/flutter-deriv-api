package BOM::Product::ContractFinder::MultiBarrier;

use strict;
use warnings;

use BOM::Product::Contract::PredefinedParameters qw(get_trading_periods get_available_barriers get_expired_barriers);
use List::Util qw(max);
use Time::Duration::Concise;

sub decorate {
    my $args = shift;

    my ($underlying, $offerings, $calendar, $date) = @{$args}{'underlying', 'offerings', 'calendar', 'date'};

    my $trading_periods = get_trading_periods($underlying->symbol, $underlying->for_date);
    my $closing         = $calendar->closing_on($underlying->exchange, $date);
    return [] unless @$trading_periods and $closing;
    my $close_epoch = $closing->epoch;
    # full trading seconds
    my $trading_seconds = $close_epoch - $date->truncate_to_day->epoch;

    my @new_offerings;
    foreach my $offering (@$offerings) {
        my $min_duration_interval = Time::Duration::Concise->new(interval => $offering->{min_contract_duration});
        my $minimum_contract_duration;
        # we offer 0 day (end of day) and intraday durations to callputequal only
        if ($offering->{contract_category} ne 'callputequal' and $offering->{contract_category} ne 'callput') {
            $minimum_contract_duration = max(86400, $min_duration_interval->seconds);
        } else {
            # This complexity is due to the 0 day offering. For offerings when minimum contract duration is greater than 1 day, we will allow 0 day.
            $minimum_contract_duration =
                  $offering->{expiry_type} eq 'intraday' ? Time::Duration::Concise->new({interval => $offering->{min_contract_duration}})->seconds
                : $min_duration_interval->days > 1       ? $min_duration_interval->seconds
                :                                          $trading_seconds;
        }

        my $maximum_contract_duration =
            ((
                       $offering->{contract_category} eq 'callputequal'
                    or $offering->{contract_category} eq 'callput'
            )
                and $offering->{expiry_type} eq 'intraday'
            )
            ? 21600
            : Time::Duration::Concise->new({interval => $offering->{max_contract_duration}})->seconds;

        foreach my $trading_period (grep { defined } @$trading_periods) {
            my $date_expiry      = $trading_period->{date_expiry}->{epoch};
            my $date_start       = $trading_period->{date_start}->{epoch};
            my $trading_duration = $date_expiry - $date_start;
            if ($trading_duration < $minimum_contract_duration or $trading_duration > $maximum_contract_duration) {
                next;
            } elsif ($date->day_of_week == 5
                and $trading_duration < 86400
                and ($date_expiry > $close_epoch or $date_start > $close_epoch))
            {
                next;
            } else {
                my $available_barriers = get_available_barriers($underlying, $offering, $trading_period);
                my $expired_barriers =
                    ($offering->{barrier_category} eq 'american') ? get_expired_barriers($underlying, $available_barriers, $trading_period) : [];

                push @new_offerings,
                    +{
                    %{$offering},
                    trading_period     => $trading_period,
                    available_barriers => $available_barriers,
                    expired_barriers   => $expired_barriers,
                    };
            }
        }
    }

    return \@new_offerings;
}

1;

## no critic (ValuesAndExpressions::ProhibitCommaSeparatedStatements)
package BOM::Product::Contract::Finder::Japan;
use strict;
use warnings;
use Date::Utility;
use Time::Duration::Concise;
use BOM::Product::Offerings;
use BOM::Market::Underlying;
use BOM::Product::Contract::Category;
use BOM::Product::Contract::Finder qw (get_barrier);
use base qw( Exporter );
our @EXPORT_OK = qw(predefined_contracts_for_symbol);

sub predefined_contracts_for_symbol {
    my $args         = shift;
    my $symbol       = $args->{symbol} || die 'no symbol';
    my $underlying   = BOM::Market::Underlying->new($symbol);
    my $now          = Date::Utility->new;
    my $current_tick = $args->{current_tick} // $underlying->spot_tick // $underlying->tick_at($now->epoch, {allow_inconsistent => 1});

    my $exchange  = $underlying->exchange;
    my $open      = $exchange->opening_on($now)->epoch;
    my $close     = $exchange->closing_on($now)->epoch;
    my $flyby     = BOM::Product::Offerings::get_offerings_flyby;
    my @offerings = $flyby->query({
            underlying_symbol => $symbol,
            start_type        => 'spot',
            expiry_type       => ['daily', 'intraday'],
            barrier_category  => ['euro_non_atm', 'american']});

    @offerings = _predefined_trading_period({
        offerings => \@offerings,
        exchange  => $exchange
    });

    for my $o (@offerings) {
        my $cc = $o->{contract_category};
        my $bc = $o->{barrier_category};

        my $cat = BOM::Product::Contract::Category->new($cc);
        $o->{contract_category_display} = $cat->display_name;

        $o->{barriers} = $cat->two_barriers ? 2 : 1;

        # get the closest from spot barrier from the predefined set
        _set_predefined_barriers({
            underlying   => $underlying,
            current_tick => $current_tick,
            contract     => $o,
        });
    }
    return {
        available => \@offerings,
        hit_count => scalar(@offerings),
        open      => $open,
        close     => $close,
    };
}

=head2 _predefined_trading_period

We set the predefined trading periods based on Japan requirement:
1) Start at 00:00GMT and expire with duration of 2,4,6,8,12,16,20 hours
2) Start at closest even hour and expire with duration of 2 hours. Example: Current hour is 3GMT, you will have trading period of 02-04GMT.
3) Start at 00:00GMT and expire with duration of 1,2,3,7,30,60,180,365 days

=cut

my $cache_keyspace = 'FINDER_PREDEFINED_TRADING';
my $cache_sep      = '==';

sub _predefined_trading_period {
    my $args          = shift;
    my @offerings     = @{$args->{offerings}};
    my $exchange      = $args->{exchange};
    my $period_length = Time::Duration::Concise->new({interval => '2h'});    # Two hour intraday rolling periods.
    my $now           = Date::Utility->new;
    my $in_period     = $now->hour - ($now->hour % $period_length->hours);

    my $trading_key = join($cache_sep, $exchange->symbol, $now->date, $in_period);
    my $trading_periods = Cache::RedisDB->get($cache_keyspace, $trading_key);
    if (not $trading_periods) {
        my $today        = $now->truncate_to_day;                            # Start of the day object.
        my $start_of_day = $today->datetime;                                 # As a string.

        # Starting at midnight, running through these times.
        my @hourly_durations = qw(2h 3h 4h 5h);

        $trading_periods = [
            map {
                +{
                    date_start => {
                        date  => $start_of_day,
                        epoch => $today->epoch
                    },
                    date_expiry => {
                        date  => $_->datetime,
                        epoch => $_->epoch
                    },
                    duration => ($_->hour - $today->hour) . 'h'
                    }
                }
                grep {
                $now->is_before($_)
                } map {
                $today->plus_time_interval($_)
                } @hourly_durations
        ];

        # Starting at midnight, running through these dates.
        my @daily_durations = qw(1d 2d 3d 7d 30d 60d 180d 365d);
        my %added;

        foreach my $date (map { $today->plus_time_interval($_) } @daily_durations) {
            $date = $exchange->trade_date_after($date) unless ($exchange->trades_on($date));
            my $actual_day_string = $date->days_between($today) . 'd';
            next if ($added{$actual_day_string});    # We already saw this date in a previous iteration.
            $added{$actual_day_string} = 1;
            my $exchange_close_of_day = $exchange->closing_on($date);
            push @$trading_periods,
                +{
                date_start => {
                    date  => $start_of_day,
                    epoch => $today->epoch,
                },
                date_expiry => {
                    date  => $exchange_close_of_day->datetime,
                    epoch => $exchange_close_of_day->epoch,
                },
                duration => $actual_day_string,
                };
        }
        # Starting in the most recent even hour, running for.our period
        my $period_start      = $today->plus_time_interval($in_period . 'h');
        my $recent_2_hour_end = $period_start->plus_time_interval($period_length);
        push @$trading_periods,
            +{
            date_start => {
                date  => $period_start->datetime,
                epoch => $period_start->epoch,
            },
            date_expiry => {
                date  => $recent_2_hour_end->datetime,
                epoch => $recent_2_hour_end->epoch,
            },
            duration => $in_period . 'h',
            };

        # We will hold it for the duration of the period which is a little too long, but no big deal.
        Cache::RedisDB->set($cache_keyspace, $trading_key, $trading_periods, $period_length->seconds);
    }

    my @new_offerings;
    foreach my $o (@offerings) {
        my $minimum_contract_duration = Time::Duration::Concise->new({interval => $o->{min_contract_duration}})->seconds;
        foreach my $trading_period (@$trading_periods) {
            if (Time::Duration::Concise->new({interval => $trading_period->{duration}})->seconds < $minimum_contract_duration) {
                next;
            } else {
                push @new_offerings, {%{$o}, trading_period => $trading_period};
            }
        }
    }

    return @new_offerings;
}

=head2 _set_predefined_barriers

To set the predefined barriers on each trading period.
We will take strike from 35,40,45 ,50,55,60,65 delta.

=cut

sub _set_predefined_barriers {
    my $args = shift;
    my ($underlying, $contract, $current_tick) = @{$args}{'underlying', 'contract', 'current_tick'};

    my $trading_period = $contract->{trading_period};
    my $date_start     = Date::Utility->new($trading_period->{date_start}->{epoch});
    my $date_expiry    = Date::Utility->new($trading_period->{date_expiry}->{epoch});

    my $barrier_key = join($cache_sep, $underlying->symbol, $date_start->epoch, $date_expiry->epoch);
    my $available_barriers = Cache::RedisDB->get($cache_keyspace, $barrier_key);
    if (not $available_barriers) {
        my $barrier_tick = $underlying->tick_at($date_start->epoch) // $current_tick;
        my $duration     = $date_expiry->epoch - $date_start->epoch;
        my @delta        = (0.35, 0.4, 0.45, 0.52, 0.55, 0.6, 0.65);
        foreach my $delta (@delta) {
            push @$available_barriers, [
                map {
                    get_barrier({
                            underlying       => $underlying,
                            duration         => $duration,
                            direction        => $_,
                            barrier_delta    => $delta,
                            barrier_tick     => $barrier_tick,
                            absolute_barrier => 1,
                            atm_vol          => 0.1
                        })
                } (qw(high low))];
        }
        # Expires at the end of the available period.
        Cache::RedisDB->set($cache_keyspace, $barrier_key, $available_barriers, $date_expiry->epoch - time);
    }
    if ($contract->{barriers} == 1) {
        $contract->{available_barriers} = [map { $_->[0] } @$available_barriers];
        $contract->{barrier} = (sort { abs($current_tick->quote - $a) <=> abs($current_tick->quote - $b) } @{$contract->{available_barriers}})[0];
    } elsif ($contract->{barriers} == 2) {
        $contract->{available_barriers} = $available_barriers;
        ($contract->{high_barrier}, $contract->{low_barrier}) =
            @{(sort { abs($current_tick->quote - $a->[0]) <=> abs($current_tick->quote - $b->[0]) } @{$contract->{available_barriers}})[0]};
    }

    return;
}
1;

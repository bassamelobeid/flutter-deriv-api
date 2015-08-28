package BOM::Product::Contract::Finder::Japan;
use strict;
use warnings;
use Date::Utility;
use Time::Duration::Concise;
use BOM::Product::Offerings;
use BOM::Market::Underlying;
use BOM::Product::Contract::Category;
use Format::Util::Numbers qw(roundnear);
use base qw( Exporter );
use BOM::Product::ContractFactory qw(produce_contract);
our @EXPORT_OK = qw(available_contracts_for_symbol);

=head1 available_contracts_for_symbol

Returns a set of available contracts for a particular contract which included predefined trading period and 20 predefined barriers associated with the trading period

=cut

sub available_contracts_for_symbol {
    my $args         = shift;
    my $symbol       = $args->{symbol} || die 'no symbol';
    my $underlying   = BOM::Market::Underlying->new($symbol);
    my $now          = $args->{date} || Date::Utility->new;
    my $current_tick = $args->{current_tick} // $underlying->spot_tick // $underlying->tick_at($now->epoch, {allow_inconsistent => 1});

    my $exchange = $underlying->exchange;
    my ($open, $close);
    if ($exchange->trades_on($now)) {
        $open  = $exchange->opening_on($now)->epoch;
        $close = $exchange->closing_on($now)->epoch;
    }
    my $flyby     = BOM::Product::Offerings::get_offerings_flyby;
    my @offerings = $flyby->query({
            underlying_symbol => $symbol,
            start_type        => 'spot',
            expiry_type       => ['daily', 'intraday'],
            barrier_category  => ['euro_non_atm', 'american']});
    @offerings = _predefined_trading_period({
        offerings => \@offerings,
        exchange  => $exchange,
        date      => $now,
    });

    for my $o (@offerings) {
        my $cc = $o->{contract_category};
        my $bc = $o->{barrier_category};

        my $cat = BOM::Product::Contract::Category->new($cc);
        $o->{contract_category_display} = $cat->display_name;

        $o->{barriers} = $cat->two_barriers ? 2 : 1;

        _set_predefined_barriers({
            underlying   => $underlying,
            current_tick => $current_tick,
            contract     => $o,
            date         => $now,
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
1) Start at 00:00GMT and expire with duration of 2,3,4 and 5 hours
2) Start at closest even hour and expire with duration of 2,3,4,5 hours. Example: Current hour is 3GMT, you will have trading period of 02-04GMT, 02-05GMT, 02-06GMT, 02-07GMT.
3) Start at 00:00GMT and expire with duration of 1,2,3,7,30,60,180,365 days

=cut

my $cache_keyspace = 'FINDER_PREDEFINED_TRADING';
my $cache_sep      = '==';

sub _predefined_trading_period {
    my $args            = shift;
    my @offerings       = @{$args->{offerings}};
    my $exchange        = $args->{exchange};
    my $period_length   = Time::Duration::Concise->new({interval => '2h'});              # Two hour intraday rolling periods.
    my $now             = $args->{date};
    my $in_period       = $now->hour - ($now->hour % $period_length->hours);
    my $trading_key     = join($cache_sep, $exchange->symbol, $now->date, $in_period);
    my $today_close     = $exchange->closing_on($now);
    my $trading_periods = Cache::RedisDB->get($cache_keyspace, $trading_key);
    if (not $trading_periods) {
        my $today        = $now->truncate_to_day;                                        # Start of the day object.
        my $start_of_day = $today->datetime;                                             # As a string.

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
        # Starting in the most recent even hour, running through those hours
        my $period_start = $today->plus_time_interval($in_period . 'h');
        push @$trading_periods, map {
            +{
                date_start => {
                    date  => $period_start->datetime,
                    epoch => $period_start->epoch,
                },
                date_expiry => {
                    date  => $_->datetime,
                    epoch => $_->epoch,
                },
                duration => ($_->hour - $period_start->hour) . 'h',
                }
            } grep {
            $now->is_before($_) and $period_start->hour > 0 and $period_start->epoch < $today_close->epoch
            } map {
            $period_start->plus_time_interval($_)
            } @hourly_durations;
        # We will hold it for the duration of the period which is a little too long, but no big deal.
        Cache::RedisDB->set($cache_keyspace, $trading_key, $trading_periods, $period_length->seconds);
    }

    my @new_offerings;
    foreach my $o (@offerings) {
        my $minimum_contract_duration = Time::Duration::Concise->new({interval => $o->{min_contract_duration}})->seconds;
        foreach my $trading_period (@$trading_periods) {
            if (Time::Duration::Concise->new({interval => $trading_period->{duration}})->seconds < $minimum_contract_duration) {
                next;
            } elsif ($now->day_of_week == 5 and $trading_period->{date_expiry}->epoch > $today_close->epoch) {
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
We do a binary search to find out the boundaries barriers associated with theo_prob [0.05,0.95] of a digital call,
then split into 20 barriers that within this boundaries. The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.

=cut

sub _set_predefined_barriers {
    my $args = shift;
    my ($underlying, $contract, $current_tick, $now) = @{$args}{'underlying', 'contract', 'current_tick', 'date'};

    my $trading_period     = $contract->{trading_period};
    my $date_start         = $trading_period->{date_start}->{epoch};
    my $date_expiry        = $trading_period->{date_expiry}->{epoch};
    my $duration           = $trading_period->{duration};
    my $barrier_key        = join($cache_sep, $underlying->symbol, $date_start, $date_expiry);
    my $available_barriers = Cache::RedisDB->get($cache_keyspace, $barrier_key);
    if (not $available_barriers) {
        my $start_tick = $underlying->tick_at($date_start) // $current_tick;
        my @boundaries_barrier = map {
            _get_barrier_by_probability({
                underlying    => $underlying,
                duration      => $duration,
                contract_type => 'CALL',
                start_tick    => $start_tick->quote,
                atm_vol       => 0.1,
                theo_prob     => $_,
                date_start    => $date_start
            });
        } qw(0.05 0.95);

        @$available_barriers = _split_boundaries_barriers({
            pip_size           => $underlying->pip_size,
            start_tick         => $start_tick->quote,
            boundaries_barrier => \@boundaries_barrier
        });

        # Expires at the end of the available period.
        Cache::RedisDB->set($cache_keyspace, $barrier_key, $available_barriers, $date_expiry - $now->epoch);
    }
    if ($contract->{barriers} == 1) {
        $contract->{available_barriers} = $available_barriers;
        $contract->{barrier} = (sort { abs($current_tick->quote - $a) <=> abs($current_tick->quote - $b) } @{$available_barriers})[0];
    } elsif ($contract->{barriers} == 2) {
        my @lower_barriers  = map { $_ } grep { $current_tick->quote > $_ } @{$available_barriers};
        my @higher_barriers = map { $_ } grep { $current_tick->quote < $_ } @{$available_barriers};
        $contract->{available_barriers} = [\@lower_barriers, \@higher_barriers];
        $contract->{high_barrier}       = $higher_barriers[0];
        $contract->{low_barrier}        = $lower_barriers[0];
    }

    return;
}

=head2 _split_boundaries_barriers


Split the boundaries barriers into 20 barriers.
The barriers will be split in the way more cluster towards current spot and gradually spread out from current spot.
Rules:
   -  5 barrriers with +- 1 minimum_step from previous barrier (with the start_tick as start point)
   -  2 barriers with +- 2 minimum_step from previous barrier
   -  1 barrier with +- 5  minimum_step from previous barrier
   -  1 barrier with +- 10 minimum_step from previous barrier
   -  1 barrier with +- 20 minimum_step from previous_barrier
=cut

sub _split_boundaries_barriers {
    my $args = shift;

    my $pip_size           = $args->{pip_size};
    my $spot_at_start      = $args->{start_tick};
    my @boundaries_barrier = @{$args->{boundaries_barrier}};

    my $distance_between_boundaries = abs($boundaries_barrier[0] - $boundaries_barrier[1]);
    my $minimum_step = roundnear($pip_size, $distance_between_boundaries / 88);
    my @available_barriers;
    my @steps                  = (1, 1, 1, 1, 1, 2, 2, 5, 10, 20);
    my $previous_right_barrier = $spot_at_start;
    my $previous_left_barrier  = $spot_at_start;
    foreach my $step (sort @steps) {
        my $right_barrier = $previous_right_barrier + $step * $minimum_step;
        my $left_barrier  = $previous_left_barrier - $step * $minimum_step;
        $previous_right_barrier = $right_barrier;
        $previous_left_barrier  = $left_barrier;
        push @available_barriers, ($right_barrier, $left_barrier);

    }
    return @available_barriers;
}

=head2 _get_barrier_by_probability

To get the strike that associated with a given theo probability.

=cut

sub _get_barrier_by_probability {
    my $args = shift;

    my ($underlying, $duration, $contract_type, $start_tick, $atm_vol, $target_theo_prob, $date_start) =
        @{$args}{'underlying', 'duration', 'contract_type', 'start_tick', 'atm_vol', 'theo_prob', 'date_start'};

    my $bet;

    my ($high, $low) = (1.5 * $start_tick, 0.5 * $start_tick);

    my $pip_size   = $underlying->pip_size;
    my $bet_params = {
        underlying   => $underlying,
        bet_type     => $contract_type,
        currency     => 'USD',
        payout       => 100,
        date_start   => $date_start,
        r_rate       => 0,
        q_rate       => 0,
        duration     => $duration,
        pricing_vol  => $atm_vol,
        date_pricing => $date_start,
    };

    my $iterations = 0;
    for ($iterations = 0; $iterations <= 20; $iterations++) {
        $bet_params->{'barrier'} = ($high + $low) / 2;
        $bet = produce_contract($bet_params);
        my $bet_sentiment     = $bet->sentiment;
        my $theo_prob         = $bet->theo_probability->amount;
        my $barrier_direction = $bet_params->{'barrier'} > $start_tick ? 'up' : 'down';
        if (abs($theo_prob - $target_theo_prob) < 0.01) {
            last;
        }

        if ($bet_sentiment eq 'up' or $bet_sentiment eq 'high_vol' or ($contract_type eq 'NOTOUCH' and $barrier_direction eq 'down')) {
            if ($theo_prob > $target_theo_prob) {
                $low = ($low + $high) / 2;
            } else {
                $high = ($low + $high) / 2;
            }
        } elsif ($bet_sentiment eq 'down' or $bet_sentiment eq 'low_vol' or ($contract_type eq 'ONETOUCH' and $barrier_direction eq 'down')) {
            if ($theo_prob > $target_theo_prob) {
                $high = ($low + $high) / 2;
            } else {
                $low = ($low + $high) / 2;
            }
        }
    }
    return $bet->barrier->as_absolute;
}

1;

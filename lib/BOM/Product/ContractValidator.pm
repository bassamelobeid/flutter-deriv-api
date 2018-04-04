package BOM::Product::Contract;    ## no critic ( RequireFilenameMatchesPackage )

use strict;
use warnings;

use Time::HiRes;
use Date::Utility;
use List::Util qw(any first);
use Scalar::Util::Numeric qw(isint);

use LandingCompany::Registry;

use BOM::Platform::Runtime;
use BOM::Platform::Config;
use BOM::Product::Static;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

has disable_trading_at_quiet_period => (
    is      => 'ro',
    default => 1,
);

has missing_market_data => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0
);

has skips_price_validation => (
    is      => 'ro',
    default => 0,
);

sub is_valid_to_buy {
    my $self = shift;
    my $args = shift;

    my $valid = $self->_confirm_validity($args);

    return ($self->for_sale) ? $valid : $self->_report_validation_stats('buy', $valid);
}

sub is_valid_to_sell {
    my $self = shift;
    my $args = shift;

    if ($self->category_code eq 'highlowticks') {
        $self->_add_error({
            message           => 'Resale not offered',
            message_to_client => [$ERROR_MAPPING->{ResaleNotOffered}],
        });
        return 0;
    }

    if ($self->is_sold) {
        $self->_add_error({
            message           => 'Contract already sold',
            message_to_client => [$ERROR_MAPPING->{ContractAlreadySold}],
        });
        return 0;
    }

    if ($self->is_after_settlement) {
        if (my ($ref, $hold_for_exit_tick) = $self->_validate_settlement_conditions) {
            $self->missing_market_data(1) if not $hold_for_exit_tick;
            $self->_add_error($ref);
        }
    } elsif ($self->is_after_expiry) {
        $self->_add_error({

                message           => 'waiting for settlement',
                message_to_client => [$ERROR_MAPPING->{WaitForContractSettlement}],
        });

    } elsif (not $self->is_expired) {
        if (my $ref = $self->_validate_entry_tick) {
            $self->_add_error($ref);

        } elsif (not $self->opposite_contract_for_sale->is_valid_to_buy($args)) {
            # Their errors are our errors, now!
            $self->_add_error($self->opposite_contract_for_sale->primary_validation_error);
        }
    }
    my $passes_validation = $self->primary_validation_error ? 0 : 1;
    return $self->_report_validation_stats('sell', $passes_validation);
}

sub _confirm_validity {
    my $self = shift;
    my $args = shift;

    # if there's initialization error, we will not proceed anyway.
    return 0 if $self->primary_validation_error;

    # Add any new validation methods here.
    # Looking them up can be too slow for pricing speed constraints.
    # This is the default list of validations.
    my @validation_methods = qw(_validate_input_parameters _validate_offerings);
    push @validation_methods, qw(_validate_trading_times _validate_start_and_expiry_date) unless $self->underlying->always_available;
    push @validation_methods, '_validate_barrier'                                         unless $args->{skip_barrier_validation};
    push @validation_methods, '_validate_barrier_type'                                    unless $self->for_sale;
    push @validation_methods, '_validate_feed';
    push @validation_methods, '_validate_price'                                           unless $self->skips_price_validation;
    push @validation_methods, '_validate_volsurface'                                      unless $self->volsurface->type eq 'flat';

    foreach my $method (@validation_methods) {
        if (my $err = $self->$method($args)) {
            $self->_add_error($err);
        }
        return 0 if ($self->primary_validation_error);
    }

    return 1;
}

# PRIVATE method.
sub _validate_settlement_conditions {
    my $self = shift;

    my $message;
    my $hold_for_exit_tick = 0;
    if ($self->tick_expiry) {
        if (not $self->exit_tick) {
            $message = 'exit tick undefined after 5 minutes of contract start';
        } elsif ($self->exit_tick->epoch - $self->date_start->epoch > $self->_max_tick_expiry_duration->seconds) {
            $message = 'no ticks within 5 minutes after contract start';
        }
    } else {
        # intraday or daily expiry
        if (not $self->entry_tick) {
            $message = 'entry tick is undefined';
        } elsif ($self->is_forward_starting
            and ($self->date_start->epoch - $self->entry_tick->epoch > $self->underlying->max_suspend_trading_feed_delay->seconds))
        {
            # A start now contract will not be bought if we have missing feed.
            # We are doing the same thing for forward starting contracts.
            $message = 'entry tick is too old';
        } elsif ($self->exit_tick and not $self->is_valid_exit_tick) {
            # There is pre-settlement exit tick which is not a valid exit tick for settlement
            $message            = 'exit tick is undefined';
            $hold_for_exit_tick = 1;
        } elsif ($self->entry_tick->epoch == $self->exit_tick->epoch) {
            $message = 'only one tick throughout contract period';
        } elsif ($self->entry_tick->epoch > $self->exit_tick->epoch) {
            $message = 'entry tick is after exit tick';
        }
    }

    return if not $message;

    my $refund = [$ERROR_MAPPING->{RefundBuyForMissingData}];
    my $wait   = [$ERROR_MAPPING->{WaitForContractSettlement}];

    my $ref = {
        message           => $message,
        message_to_client => ($hold_for_exit_tick ? $wait : $refund),
    };

    return ($ref, $hold_for_exit_tick);
}

# Validation methods.

# Is this underlying or contract is disabled/suspended from trading.
sub _validate_offerings {
    my $self = shift;

    my $message_to_client = [$ERROR_MAPPING->{TradeTemporarilyUnavailable}];

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->trading) {
        return {
            message           => 'All trading suspended on system',
            message_to_client => $message_to_client,
        };
    }

    my $underlying    = $self->underlying;
    my $contract_code = $self->code;
    # check if trades are suspended on that claimtype
    my $suspend_contract_types = BOM::Platform::Runtime->instance->app_config->quants->features->suspend_contract_types;
    if (@$suspend_contract_types and first { $contract_code eq $_ } @{$suspend_contract_types}) {
        return {
            message           => "Trading suspended for contract type [code: " . $contract_code . "]",
            message_to_client => $message_to_client,
        };
    }

    if (first { $_ eq $underlying->symbol } @{BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades}) {
        return {
            message           => "Underlying trades suspended [symbol: " . $underlying->symbol . "]",
            message_to_client => $message_to_client,
        };
    }

    # NOTE: this check only validates the contract-specific risk profile.
    # There may also be a client specific one which is validated in B:P::Transaction
    if ($self->risk_profile->get_risk_profile eq 'no_business') {
        return {
            message           => 'manually disabled by quants',
            message_to_client => $message_to_client,
        };
    }

    return;
}

sub _validate_entry_tick {
    my $self = shift;

    return if $self->starts_as_forward_starting;

    my $underlying = $self->underlying;

    if (not $self->entry_spot) {
        return {
            message           => "Waiting for entry tick [symbol: " . $self->underlying->symbol . "]",
            message_to_client => [$ERROR_MAPPING->{EntryTickMissing}],
        };
    }

    return;
}

sub maximum_feed_delay_seconds {
    my $self = shift;

    my $underlying = $self->underlying;

    return $underlying->max_suspend_trading_feed_delay->seconds if $underlying->market->name ne 'forex' or $self->is_forward_starting;

    my $effective_epoch = $self->effective_start->epoch;
    my @events_in_the_last_15_seconds =
        grep { $_->{release_date} >= $effective_epoch - 15 && $_->{release_date} <= $effective_epoch && $_->{vol_change} > 0.25 }
        @{$self->_applicable_economic_events};

    # We want to have a stricter feed delay threshold (2 seconds) if there's a level 5 economic event.
    return 2
        if @events_in_the_last_15_seconds && $events_in_the_last_15_seconds[-1]->{release_date} > $self->current_tick->epoch;
    return $underlying->max_suspend_trading_feed_delay->seconds;
}

sub _validate_feed {
    my $self = shift;

    return if $self->is_expired;

    my $underlying = $self->underlying;

    if (not $self->current_tick) {
        warn "No current_tick for " . $underlying->symbol;
        return {
            message           => "No realtime data [symbol: " . $underlying->symbol . "]",
            message_to_client => [$ERROR_MAPPING->{MissingTickMarketData}],
        };
    } elsif ($self->trading_calendar->is_open_at($underlying->exchange, $self->date_pricing)
        && $self->date_pricing->epoch - $self->maximum_feed_delay_seconds > $self->current_tick->epoch)
    {
        return {
            message           => "Quote too old [symbol: " . $underlying->symbol . "]",
            message_to_client => [$ERROR_MAPPING->{OldMarketData}],
        };
    }

    return;
}

sub _validate_price {
    my $self = shift;

    return if $self->for_sale;

    $self->_set_price_calculator_params('validate_price');
    my $res = $self->price_calculator->validate_price;
    if ($res && exists $res->{error_code}) {
        my $details = $res->{error_details} || [];
        $res = {
            zero_stake => sub {
                my ($details) = @_;
                return {
                    message           => "Empty or zero stake [stake: " . $details->[0] . "]",
                    message_to_client => [$ERROR_MAPPING->{InvalidStake}],
                };
            },
            stake_outside_range => sub {
                my ($details) = @_;
                my $params = [$details->[0], $details->[1]];
                return {
                    message           => 'stake is not within limits ' . "[stake: " . $details->[0] . "] " . "[min: " . $details->[1] . "] ",
                    message_to_client => [$ERROR_MAPPING->{StakePayoutLimits}, @$params],
                };
            },
            payout_outside_range => sub {
                my ($details) = @_;
                my $params = [$details->[0], $details->[1]];
                return {
                    message => 'payout amount outside acceptable range ' . "[given: " . $details->[0] . "] " . "[max: " . $details->[1] . "]",
                    message_to_client => [$ERROR_MAPPING->{StakePayoutLimits}, @$params],
                };
            },
            payout_too_many_places => sub {
                my ($details) = @_;
                return {
                    message => 'payout amount has too many decimal places ' . "[permitted: " . $details->[0] . "] [payout: " . $details->[1] . "]",
                    message_to_client => [$ERROR_MAPPING->{IncorrectPayoutDecimals}, $details->[0]],
                };
            },
            stake_same_as_payout => sub {
                my ($details) = @_;
                return {
                    message           => 'stake same as payout',
                    message_to_client => [$ERROR_MAPPING->{NoReturn}],
                };
            },
        }->{$res->{error_code}}->($details);
    }
    return $res;
}

sub _validate_barrier_type {
    my $self = shift;

    return if $self->tick_expiry;

    # The barrier for atm bet is always SOP which is relative
    return if ($self->is_atm_bet and defined $self->barrier and $self->barrier->barrier_type eq 'relative');

    # intraday non ATM barrier could be absolute or relative
    return if $self->is_intraday;

    foreach my $barrier ($self->two_barriers ? ('high_barrier', 'low_barrier') : ('barrier')) {
        # For multiday, the barrier must be absolute.
        # For intraday, the barrier can be absolute or relative.
        if (defined $self->$barrier and $self->$barrier->barrier_type ne 'absolute') {

            return {
                message           => 'barrier should be absolute for multi-day contracts',
                message_to_client => [$ERROR_MAPPING->{NeedAbsoluteBarrier}],
            };
        }
    }
    return;

}

sub _validate_input_parameters {
    my $self = shift;

    my $when_epoch       = $self->date_pricing->epoch;
    my $epoch_expiry     = $self->date_expiry->epoch;
    my $epoch_start      = $self->date_start->epoch;
    my $epoch_settlement = $self->date_settlement->epoch;

    if ($epoch_expiry == $epoch_start) {
        return {
            message           => 'Start and Expiry times are the same ' . "[start: " . $epoch_start . "] " . "[expiry: " . $epoch_expiry . "]",
            message_to_client => [$ERROR_MAPPING->{SameExpiryStartTime}],
        };
    } elsif ($epoch_expiry < $epoch_start) {
        return {
            message           => 'Start must be before expiry ' . "[start: " . $epoch_start . "] " . "[expiry: " . $epoch_expiry . "]",
            message_to_client => [$ERROR_MAPPING->{PastExpiryTime}],
        };
    } elsif (not $self->for_sale and $epoch_start < $when_epoch) {
        return {
            message           => 'starts in the past ' . "[start: " . $epoch_start . "] " . "[now: " . $when_epoch . "]",
            message_to_client => [$ERROR_MAPPING->{PastStartTime}],
        };
    } elsif (not $self->is_forward_starting and $epoch_start > $when_epoch) {
        return {
            message           => "Forward time for non-forward-starting contract type [code: " . $self->code . "]",
            message_to_client => [$ERROR_MAPPING->{FutureStartTime}],
        };
    } elsif ($self->is_forward_starting and not $self->for_sale) {
        # Intraday cannot be bought in the 5 mins before the bet starts, unless we've built it for that purpose.
        my $fs_blackout_seconds = 300;
        if ($epoch_start < $when_epoch + $fs_blackout_seconds) {
            return {
                message           => "forward-starting blackout [blackout: " . $fs_blackout_seconds . "s]",
                message_to_client => [$ERROR_MAPPING->{ForwardStartTime}],
            };
        }
    } elsif ($self->is_after_settlement) {
        return {
            message           => 'already expired contract',
            message_to_client => [$ERROR_MAPPING->{AlreadyExpired}],
        };
    } elsif ($self->expiry_daily) {
        my $date_expiry = $self->date_expiry;
        my $closing = $self->trading_calendar->closing_on($self->underlying->exchange, $date_expiry);
        if ($closing and not $date_expiry->is_same_as($closing)) {
            return {
                message => 'daily expiry must expire at close '
                    . "[expiry: "
                    . $date_expiry->datetime . "] "
                    . "[underlying_symbol: "
                    . $self->underlying->symbol . "]",
                message_to_client => [$ERROR_MAPPING->{TradingDayEndExpiry}],
            };
        }
    }

    if ($self->category_code eq 'lookback') {

        if ($self->multiplier < $self->minimum_multiplier) {
            return {
                message           => 'below minimum allowed multiplier',
                message_to_client => [$ERROR_MAPPING->{MinimumMultiplier} . ' ' . $self->minimum_multiplier . '.'],
            };
        } elsif (not isint($self->multiplier * 1000)) {
            return {
                message           => 'Multiplier cannot be more than 3 decimal places.',
                message_to_client => [$ERROR_MAPPING->{MultiplierDecimalPlace}],
            };
        }
    }

    return;
}

sub _validate_trading_times {
    my $self = shift;
    my $args = shift;

    my $underlying  = $self->underlying;
    my $exchange    = $underlying->exchange;
    my $calendar    = $self->trading_calendar;
    my $date_expiry = $self->date_expiry;
    my $date_start  = $self->date_start;
    my $volidx_flag = 1;
    my ($markets, $lc);

    if (not($calendar->trades_on($exchange, $date_start) and $calendar->is_open_at($exchange, $date_start))) {
        if ($args->{landing_company}) {
            $lc          = LandingCompany::Registry::get($args->{landing_company});
            $markets     = $lc->legal_allowed_markets if $lc;
            $volidx_flag = any { $_ eq 'volidx' } @$markets;
        }
        my $message;
        if ($volidx_flag) {
            $message = $self->is_forward_starting ? $ERROR_MAPPING->{MarketNotOpenTryVolatility} : $ERROR_MAPPING->{MarketIsClosedTryVolatility};
        } else {
            $message = $self->is_forward_starting ? $ERROR_MAPPING->{MarketNotOpen} : $ERROR_MAPPING->{MarketIsClosed};
        }

        return {
            message => 'underlying is closed at start ' . "[symbol: " . $underlying->symbol . "] " . "[start: " . $date_start->datetime . "]",
            message_to_client => [$message]};
    } elsif (not $calendar->trades_on($exchange, $date_expiry)) {
        return ({
            message           => "Exchange is closed on expiry date [expiry: " . $date_expiry->date . "]",
            message_to_client => [$ERROR_MAPPING->{TradingDayExpiry}],
        });
    }

    if ($self->is_intraday) {
        if (not $calendar->is_open_at($exchange, $date_expiry)) {
            return {
                message => 'underlying closed at expiry ' . "[symbol: " . $underlying->symbol . "] " . "[expiry: " . $date_expiry->datetime . "]",
                message_to_client => [$ERROR_MAPPING->{TradingHoursExpiry}],
            };
        } elsif ($underlying->intradays_must_be_same_day and $calendar->closing_on($exchange, $date_start)->epoch < $date_expiry->epoch) {
            return {
                message           => "Intraday duration must expire on same day [symbol: " . $underlying->symbol . "]",
                message_to_client => [$ERROR_MAPPING->{SameTradingDayExpiry}],
            };
        }
    } elsif ($self->expiry_daily and not $self->is_atm_bet) {
        # For definite ATM contracts we do not have to check for upcoming holidays.
        my $trading_days = $calendar->trading_days_between($exchange, $date_start, $date_expiry);
        my $holiday_days = $calendar->holiday_days_between($exchange, $date_start, $date_expiry);
        my $calendar_days = $date_expiry->days_between($date_start);

        if ($underlying->market->equity and $trading_days <= 4 and $holiday_days >= 2) {
            my $safer_expiry = $date_expiry;
            my $trade_count  = $trading_days;
            while ($trade_count < 4) {
                $safer_expiry = $calendar->trade_date_after($exchange, $safer_expiry);
                $trade_count++;
            }
            my $message =
                  ($self->for_sale)
                ? [$ERROR_MAPPING->{ResaleNotOfferedHolidays}]
                : [$ERROR_MAPPING->{TooManyHolidays}];
            return {
                message => 'Not enough trading days for calendar days ' . "[trading: " . $trading_days . "] " . "[calendar: " . $calendar_days . "]",
                message_to_client => $message,
            };
        }
    }

    return;
}

=head2 forward_blackouts

Periods of which we decide to stay out of the market due to high uncertainty for forward contracts ONLY.

=cut

has forward_blackouts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_forward_blackouts {
    my $self = shift;

    my $forward_starting_contract = ($self->starts_as_forward_starting or $self->is_forward_starting);

    return [] if not $forward_starting_contract;

    my @blackout_periods;
    my $effective_sod = $self->effective_start->truncate_to_day;
    my $underlying    = $self->underlying;

    if ($self->is_intraday) {
        if (my @inefficient_periods = @{$underlying->forward_inefficient_periods}) {
            push @blackout_periods, [$effective_sod->plus_time_interval($_->{start})->epoch, $effective_sod->plus_time_interval($_->{end})->epoch]
                for @inefficient_periods;
        }
    }

    return \@blackout_periods;

}

sub _validate_start_and_expiry_date {
    my $self = shift;

    my $start_epoch = $self->effective_start->epoch;
    my $end_epoch   = $self->date_expiry->epoch;
    #Note: Please don't change the message for expiry blackout (specifically, the 'expire' word) unless you have
    #updated the check in this method which updates end_epoch
    my @blackout_checks = (
        [[$start_epoch], $self->date_start_blackouts,  $ERROR_MAPPING->{TradingNotAvailable}],
        [[$end_epoch],   $self->date_expiry_blackouts, $ERROR_MAPPING->{ContractExpiryNotAllowed}],
        [[$start_epoch, $end_epoch], $self->market_risk_blackouts, $ERROR_MAPPING->{TradingNotAvailable}],
        [[$start_epoch, $end_epoch], $self->forward_blackouts,     $ERROR_MAPPING->{TradingNotAvailable}],
    );

    # disable contracts with duration < 5 hours at 21:00 to 24:00GMT due to quiet period.
    # did not inlcude this in date_start_blackouts because we want a different message to client.
    if ($self->disable_trading_at_quiet_period and ($self->underlying->market->name eq 'forex' or $self->underlying->market->name eq 'commodities')) {
        my $pricing_hour = $self->date_pricing->hour;
        my $five_hour_in_years = 5 * 3600 / (86400 * 365);
        if ($self->timeinyears->amount < $five_hour_in_years && ($pricing_hour >= 21 && $pricing_hour < 24)) {
            my $pricing_date = $self->date_pricing->date;
            push @blackout_checks,
                [
                [$start_epoch],
                [[map { Date::Utility->new($pricing_date)->plus_time_interval($_)->epoch } qw(21h 23h59m59s)]],
                $ERROR_MAPPING->{TradingSuspendedSpecificHours}];
        }
    }

    foreach my $blackout (@blackout_checks) {
        my ($epochs, $periods, $message_to_client) = @{$blackout}[0 .. 2];
        my @args = ();
        foreach my $period (@$periods) {
            my $start_epoch = $period->[0];
            my $end_epoch   = $period->[1];

            $end_epoch++ if ($message_to_client =~ /expire/);

            if (first { $_ >= $start_epoch and $_ < $end_epoch } @$epochs) {
                my $start = Date::Utility->new($period->[0]);
                my $end   = Date::Utility->new($period->[1]);
                if ($start->day_of_year == $end->day_of_year) {
                    push @args, ($start->time_hhmmss, $end->time_hhmmss);
                } else {
                    push @args, ($start->date, $end->date);
                }
                return {
                    message => 'blackout period '
                        . "[symbol: "
                        . $self->underlying->symbol . "] "
                        . "[from: "
                        . $period->[0] . "] " . "[to: "
                        . $period->[1] . "]",
                    message_to_client => [$message_to_client, @args],
                };
            }
        }
    }

    return;
}

sub _validate_volsurface {
    my $self = shift;

    my $volsurface  = $self->volsurface;
    my $now         = $self->date_pricing;
    my $surface_age = ($now->epoch - $volsurface->creation_date->epoch) / 3600;

    if ($volsurface->validation_error) {
        warn "Volsurface validation error for " . $self->underlying->symbol;
        return {
            message           => "Volsurface has smile flags [symbol: " . $self->underlying->symbol . "]",
            message_to_client => [$ERROR_MAPPING->{MissingVolatilityMarketData}],
        };
    }

    my $exceeded;
    if (    $self->market->name eq 'forex'
        and not $self->priced_with_intraday_model
        and $self->timeindays->amount < 4
        and not $self->is_atm_bet
        and $surface_age > 6)
    {
        $exceeded = '6h';
    } elsif ($self->market->name eq 'indices' and $surface_age > 24 and not $self->is_atm_bet) {
        $exceeded = '24h';
    } elsif ($volsurface->creation_date->days_between($self->trading_calendar->trade_date_before($self->underlying->exchange, $now)) < 0) {
        # will discuss if this can be removed.
        $exceeded = 'different day';
    }

    if ($exceeded) {
        warn "volsurface too old - " . $self->underlying->symbol . " " . "[age: " . $surface_age . "h] " . "[max: " . $exceeded . "]";
        return {
            message => 'volsurface too old '
                . "[symbol: "
                . $self->underlying->symbol . "] "
                . "[age: "
                . $surface_age . "h] "
                . "[max: "
                . $exceeded . "]",
            message_to_client => [$ERROR_MAPPING->{OutdatedVolatilityData}],
        };
    }

    if ($volsurface->type eq 'moneyness' and my $current_spot = $self->current_spot) {
        if (abs($volsurface->spot_reference - $current_spot) / $current_spot * 100 > 5) {
            warn 'spot too far from surface reference '
                . "[symbol: "
                . $self->underlying->symbol . "] "
                . "[spot: "
                . $current_spot . "] "
                . "[surface reference: "
                . $volsurface->spot_reference . "]";

            return {
                message => 'spot too far from surface reference '
                    . "[symbol: "
                    . $self->underlying->symbol . "] "
                    . "[spot: "
                    . $current_spot . "] "
                    . "[surface reference: "
                    . $volsurface->spot_reference . "]",
                message_to_client => [$ERROR_MAPPING->{MissingSpotMarketData}],
            };
        }
    }

    return;
}

=head2 market_risk_blackouts

Periods of which we decide to stay out of the market due to high uncertainty.

=cut

has market_risk_blackouts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_market_risk_blackouts {
    my $self = shift;

    my @blackout_periods;
    my $effective_sod = $self->effective_start->truncate_to_day;
    my $underlying    = $self->underlying;

    if ($self->is_intraday) {
        if (my @inefficient_periods = @{$underlying->inefficient_periods}) {
            push @blackout_periods, [$effective_sod->plus_time_interval($_->{start})->epoch, $effective_sod->plus_time_interval($_->{end})->epoch]
                for @inefficient_periods;
        }
    }

    return \@blackout_periods;
}

has date_expiry_blackouts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_date_expiry_blackouts {
    my $self = shift;

    my @periods;
    my $underlying = $self->underlying;
    my $date_start = $self->date_start;

    if ($self->is_intraday) {
        my $end_of_trading = $self->trading_calendar->closing_on($underlying->exchange, $self->date_start);
        if ($end_of_trading and my $expiry_blackout = $underlying->eod_blackout_expiry) {
            push @periods, [$end_of_trading->minus_time_interval($expiry_blackout)->epoch, $end_of_trading->epoch];
        }
    } elsif ($self->expiry_daily and $underlying->market->equity and not $self->is_atm_bet) {
        my $start_of_period = BOM::Platform::Config::quants->{bet_limits}->{holiday_blackout_start};
        my $end_of_period   = BOM::Platform::Config::quants->{bet_limits}->{holiday_blackout_end};
        if ($self->date_start->day_of_year >= $start_of_period or $self->date_start->day_of_year <= $end_of_period) {
            my $year = $self->date_start->day_of_year > $start_of_period ? $date_start->year : $date_start->year - 1;
            my $end_blackout = Date::Utility->new($year . '-12-31')->plus_time_interval($end_of_period . 'd23h59m59s');
            push @periods, [$self->date_start->epoch, $end_blackout->epoch];
        }
    }

    return \@periods;
}

has date_start_blackouts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_date_start_blackouts {
    my $self = shift;

    my @periods;
    my $underlying = $self->underlying;
    my $calendar   = $self->trading_calendar;
    my $start      = $self->date_start;

    # We need to set sod_blackout_start for forex if the previous calendar day is a non-trading day. Otherwise, if there is no tick ,it will always take last tick on the day before and trigger missing feed check.
    if (my $sod = $calendar->opening_on($underlying->exchange, $start)) {
        my $sod_blackout =
            ($underlying->sod_blackout_start) ? $underlying->sod_blackout_start
            : (     $underlying->market->name eq 'forex'
                and $self->is_forward_starting
                and not $self->trading_calendar->trades_on($self->underlying->exchange, $start->minus_time_interval('1d'))) ? '10m'
            : '';
        if ($sod_blackout) {
            push @periods, [$sod->epoch, $sod->plus_time_interval($sod_blackout)->epoch];
        }
    }

    my $end_of_trading = $calendar->closing_on($underlying->exchange, $start);
    if ($end_of_trading) {
        if ($self->is_intraday) {
            my $eod_blackout =
                ($self->tick_expiry and ($underlying->resets_at_open or ($underlying->market->name eq 'forex' and $start->day_of_week == 5)))
                ? $self->_max_tick_expiry_duration
                : $underlying->eod_blackout_start;
            push @periods, [$end_of_trading->minus_time_interval($eod_blackout)->epoch, $end_of_trading->epoch] if $eod_blackout;
        }
    }

    return \@periods;
}

1;

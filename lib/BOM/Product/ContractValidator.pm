package BOM::Product::Contract;    ## no critic ( RequireFilenameMatchesPackage )

use strict;
use warnings;

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

    if ($self->is_sold) {
        $self->add_error({
            message           => 'Contract already sold',
            message_to_client => localize("This contract has been sold."),
        });
        return 0;
    }

    if ($self->is_after_settlement) {
        if (my ($ref, $hold_for_exit_tick) = $self->_validate_settlement_conditions) {
            $self->missing_market_data(1) if not $hold_for_exit_tick;
            $self->add_error($ref);
        }
    } elsif ($self->is_after_expiry) {
        $self->add_error({

                message => 'waiting for settlement',
                message_to_client =>
                    localize('Please wait for contract settlement. The final settlement price may differ from the indicative price.'),
        });

    } elsif (not $self->is_expired and not $self->opposite_contract->is_valid_to_buy($args)) {
        # Their errors are our errors, now!
        $self->add_error($self->opposite_contract->primary_validation_error);
    }

    if (scalar @{$self->corporate_actions}) {
        $self->add_error({
            message           => "affected by corporate action [symbol: " . $self->underlying->symbol . "]",
            message_to_client => localize("This contract is affected by corporate action."),
        });
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
    push @validation_methods, '_validate_lifetime';
    push @validation_methods, '_validate_barrier'                                         unless $args->{skip_barrier_validation};
    push @validation_methods, '_validate_barrier_type'                                    unless $self->for_sale;
    push @validation_methods, '_validate_feed';
    push @validation_methods, '_validate_price'                                           unless $self->skips_price_validation;
    push @validation_methods, '_validate_volsurface'                                      unless $self->volsurface->type eq 'flat';
    push @validation_methods, '_validate_appconfig_age';

    foreach my $method (@validation_methods) {
        if (my $err = $self->$method) {
            $self->add_error($err);
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
        } elsif ($self->exit_tick->epoch - $self->date_start->epoch > $self->max_tick_expiry_duration->seconds) {
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
        } elsif (not $self->exit_tick) {
            $message            = 'exit tick is undefined';
            $hold_for_exit_tick = 1;
        } elsif ($self->entry_tick->epoch == $self->exit_tick->epoch) {
            $message = 'only one tick throughout contract period';
        } elsif ($self->entry_tick->epoch > $self->exit_tick->epoch) {
            $message = 'entry tick is after exit tick';
        }
    }

    return if not $message;

    my $refund = 'The buy price of this contract will be refunded due to missing market data.';
    my $wait   = 'Please wait for contract settlement.';

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

    my $message_to_client = localize('This trade is temporarily unavailable.');

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

    if (first { $_ eq $underlying->symbol } @{BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions}) {
        return {
            message           => "Underlying trades suspended due to corporate actions [symbol: " . $underlying->symbol . "]",
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

sub _validate_feed {
    my $self = shift;

    return if $self->is_expired;

    my $underlying = $self->underlying;

    if (not $self->current_tick) {
        return {
            message           => "No realtime data [symbol: " . $underlying->symbol . "]",
            message_to_client => localize('Trading on this market is suspended due to missing market data.'),
        };
    } elsif ($self->calendar->is_open_at($self->date_pricing)
        and $self->date_pricing->epoch - $underlying->max_suspend_trading_feed_delay->seconds > $self->current_tick->epoch)
    {
        # only throw errors for quote too old, if the exchange is open at pricing time
        return {
            message           => "Quote too old [symbol: " . $underlying->symbol . "]",
            message_to_client => localize('Trading on this market is suspended due to missing market data.'),
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
                    message_to_client => localize("Invalid stake"),
                };
            },
            stake_outside_range => sub {
                my ($details) = @_;
                my $localize_params = [to_monetary_number_format($details->[0]), to_monetary_number_format($details->[1])];
                return {
                    message                 => 'stake is not within limits ' . "[stake: " . $details->[0] . "] " . "[min: " . $details->[1] . "] ",
                    message_to_client       => localize('Minimum stake of [_1] and maximum payout of [_2]', @$localize_params),
                    message_to_client_array => ['Minimum stake of [_1] and maximum payout of [_2]', @$localize_params],
                };
            },
            payout_outside_range => sub {
                my ($details) = @_;
                my $localize_params = [to_monetary_number_format($details->[0]), to_monetary_number_format($details->[1])];
                return {
                    message => 'payout amount outside acceptable range ' . "[given: " . $details->[0] . "] " . "[max: " . $details->[1] . "]",
                    message_to_client => localize('Minimum stake of [_1] and maximum payout of [_2]', @$localize_params),
                    message_to_client_array => ['Minimum stake of [_1] and maximum payout of [_2]', @$localize_params],
                };
            },
            payout_too_many_places => sub {
                my ($details) = @_;
                return {
                    message           => 'payout amount has too many decimal places ' . "[permitted: 2] " . "[payout: " . $details->[0] . "]",
                    message_to_client => localize('Payout may not have more than two decimal places.'),
                };
            },
            stake_same_as_payout => sub {
                my ($details) = @_;

                $self->continue_price_stream(1);

                return {
                    message           => 'stake same as payout',
                    message_to_client => localize('This contract offers no return.'),
                };
            },
        }->{$res->{error_code}}->($details);
    }
    return $res;
}

sub _validate_barrier_type {
    my $self = shift;

    return if ($self->tick_expiry or $self->is_spread);

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
                message_to_client => localize('Contracts more than 24 hours in duration would need an absolute barrier.'),
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
            message_to_client => localize('Expiry time cannot be equal to start time.'),
        };
    } elsif ($epoch_expiry < $epoch_start) {
        return {
            message           => 'Start must be before expiry ' . "[start: " . $epoch_start . "] " . "[expiry: " . $epoch_expiry . "]",
            message_to_client => localize("Expiry time cannot be in the past."),
        };
    } elsif (not $self->for_sale and $epoch_start < $when_epoch) {
        return {
            message           => 'starts in the past ' . "[start: " . $epoch_start . "] " . "[now: " . $when_epoch . "]",
            message_to_client => localize("Start time is in the past"),
        };
    } elsif (not $self->is_forward_starting and $epoch_start > $when_epoch) {
        return {
            message           => "Forward time for non-forward-starting contract type [code: " . $self->code . "]",
            message_to_client => localize('Start time is in the future.'),
        };
    } elsif ($self->is_forward_starting and not $self->for_sale) {
        # Intraday cannot be bought in the 5 mins before the bet starts, unless we've built it for that purpose.
        my $fs_blackout_seconds = 300;
        if ($epoch_start < $when_epoch + $fs_blackout_seconds) {
            return {
                message           => "forward-starting blackout [blackout: " . $fs_blackout_seconds . "s]",
                message_to_client => localize("Start time on forward-starting contracts must be more than 5 minutes from now."),
            };
        }
    } elsif ($self->is_after_settlement) {
        return {
            message           => 'already expired contract',
            message_to_client => localize("Contract has already expired."),
        };
    } elsif ($self->expiry_daily) {
        my $date_expiry = $self->date_expiry;
        my $closing     = $self->calendar->closing_on($date_expiry);
        if ($closing and not $date_expiry->is_same_as($closing)) {
            return {
                message => 'daily expiry must expire at close '
                    . "[expiry: "
                    . $date_expiry->datetime . "] "
                    . "[underlying_symbol: "
                    . $self->underlying->symbol . "]",
                message_to_client =>
                    localize('Contracts on this market with a duration of more than 24 hours must expire at the end of a trading day.'),
            };
        }
    }

    return;
}

sub _validate_trading_times {
    my $self = shift;

    my $underlying  = $self->underlying;
    my $calendar    = $underlying->calendar;
    my $date_expiry = $self->date_expiry;
    my $date_start  = $self->date_start;

    if (not($calendar->trades_on($date_start) and $calendar->is_open_at($date_start))) {
        my $message =
            ($self->is_forward_starting) ? localize("The market must be open at the start time.") : localize('This market is presently closed.');
        return {
            message => 'underlying is closed at start ' . "[symbol: " . $underlying->symbol . "] " . "[start: " . $date_start->datetime . "]",
            message_to_client => $message . " " . localize("Try out the Volatility Indices which are always open.")};
    } elsif (not $calendar->trades_on($date_expiry)) {
        return ({
            message           => "Exchange is closed on expiry date [expiry: " . $date_expiry->date . "]",
            message_to_client => localize("The contract must expire on a trading day."),
        });
    }

    if ($self->is_intraday) {
        if (not $calendar->is_open_at($date_expiry)) {
            return {
                message => 'underlying closed at expiry ' . "[symbol: " . $underlying->symbol . "] " . "[expiry: " . $date_expiry->datetime . "]",
                message_to_client => localize("Contract must expire during trading hours."),
            };
        } elsif ($underlying->intradays_must_be_same_day and $calendar->closing_on($date_start)->epoch < $date_expiry->epoch) {
            return {
                message           => "Intraday duration must expire on same day [symbol: " . $underlying->symbol . "]",
                message_to_client => localize('Contracts on this market with a duration of under 24 hours must expire on the same trading day.'),
            };
        }
    } elsif ($self->expiry_daily and not $self->is_atm_bet) {
        # For definite ATM contracts we do not have to check for upcoming holidays.
        my $trading_days = $self->calendar->trading_days_between($date_start, $date_expiry);
        my $holiday_days = $self->calendar->holiday_days_between($date_start, $date_expiry);
        my $calendar_days = $date_expiry->days_between($date_start);

        if ($underlying->market->equity and $trading_days <= 4 and $holiday_days >= 2) {
            my $safer_expiry = $date_expiry;
            my $trade_count  = $trading_days;
            while ($trade_count < 4) {
                $safer_expiry = $underlying->trade_date_after($safer_expiry);
                $trade_count++;
            }
            my $message =
                ($self->for_sale)
                ? localize('Resale of this contract is not offered due to market holidays during contract period.')
                : localize("Too many market holidays during the contract period.");
            return {
                message => 'Not enough trading days for calendar days ' . "[trading: " . $trading_days . "] " . "[calendar: " . $calendar_days . "]",
                message_to_client => $message,
            };
        }
    }

    return;
}

sub _validate_start_and_expiry_date {
    my $self = shift;

    my $start_epoch     = $self->effective_start->epoch;
    my $end_epoch       = $self->date_expiry->epoch;
    my @blackout_checks = (
        [[$start_epoch], $self->date_start_blackouts,  "Trading is not available from [_2] to [_3]"],
        [[$end_epoch],   $self->date_expiry_blackouts, "Contract may not expire between [_2] and [_3]"],
        [[$start_epoch, $end_epoch], $self->market_risk_blackouts, "Trading is not available from [_2] to [_3]"],
    );

    my @args = (localize($self->underlying->display_name));

    foreach my $blackout (@blackout_checks) {
        my ($epochs, $periods, $message_to_client) = @{$blackout}[0 .. 2];
        foreach my $period (@$periods) {
            if (first { $_ >= $period->[0] and $_ < $period->[1] } @$epochs) {
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
                    message_to_client => localize($message_to_client, @args),
                };
            }
        }
    }

    return;
}

sub _validate_lifetime {
    my $self = shift;

    if ($self->tick_expiry and $self->for_sale) {
        # we don't offer sellback on tick expiry contracts.
        return {
            message           => 'resale of tick expiry contract',
            message_to_client => localize('Resale of this contract is not offered.'),
        };
    }

    my $permitted = $self->permitted_expiries;
    my ($min_duration, $max_duration) = @{$permitted}{'min', 'max'};

    my $message_to_client_array;
    my $message_to_client =
        $self->for_sale
        ? localize('Resale of this contract is not offered.')
        : localize('Trading is not offered for this duration.');

    # This might be empty because we don't have short-term expiries on some contracts, even though
    # it's a valid bet type for multi-day contracts.
    if (not($min_duration and $max_duration)) {
        return {
            message           => 'trying unauthorised combination',
            message_to_client => $message_to_client,
        };
    }

    my ($duration, $message);
    if ($self->tick_expiry) {
        $duration = $self->tick_count;
        $message  = 'Invalid tick count for tick expiry';
        # slightly different message for tick expiry.
        if ($min_duration != 0) {
            $message_to_client = localize('Number of ticks must be between [_1] and [_2]', $min_duration, $max_duration);
            $message_to_client_array = ['Number of ticks must be between [_1] and [_2]', $min_duration, $max_duration];
        }
    } elsif (not $self->expiry_daily) {
        $duration = $self->get_time_to_expiry({from => $self->date_start})->seconds;
        ($min_duration, $max_duration) = ($min_duration->seconds, $max_duration->seconds);
        $message = 'Intraday duration not acceptable';
    } else {
        my $calendar = $self->calendar;
        $duration = $calendar->trading_date_for($self->date_expiry)->days_between($calendar->trading_date_for($self->date_start));
        ($min_duration, $max_duration) = ($min_duration->days, $max_duration->days);
        $message = 'Daily duration is outside acceptable range';
    }

    if ($duration < $min_duration or $duration > $max_duration) {
        return {
            message => $message . " "
                . "[duration seconds: "
                . $duration . "] "
                . "[symbol: "
                . $self->underlying->symbol . "] "
                . "[code: "
                . $self->code . "]",
            message_to_client       => $message_to_client,
            message_to_client_array => $message_to_client_array,
        };
    }

    return;
}

sub _validate_volsurface {
    my $self = shift;

    my $volsurface        = $self->volsurface;
    my $now               = $self->date_pricing;
    my $message_to_client = localize('Trading is suspended due to missing market data.');
    my $surface_age       = ($now->epoch - $volsurface->recorded_date->epoch) / 3600;

    if ($volsurface->validation_error) {
        return {
            message           => "Volsurface has smile flags [symbol: " . $self->underlying->symbol . "]",
            message_to_client => $message_to_client,
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
    } elsif ($volsurface->recorded_date->days_between($self->calendar->trade_date_before($now)) < 0) {
        # will discuss if this can be removed.
        $exceeded = 'different day';
    }

    if ($exceeded) {
        return {
            message => 'volsurface too old '
                . "[symbol: "
                . $self->underlying->symbol . "] "
                . "[age: "
                . $surface_age . "h] "
                . "[max: "
                . $exceeded . "]",
            message_to_client => $message_to_client,
        };
    }

    if ($volsurface->type eq 'moneyness' and my $current_spot = $self->current_spot) {
        if (abs($volsurface->spot_reference - $current_spot) / $current_spot * 100 > 5) {
            return {
                message => 'spot too far from surface reference '
                    . "[symbol: "
                    . $self->underlying->symbol . "] "
                    . "[spot: "
                    . $current_spot . "] "
                    . "[surface reference: "
                    . $volsurface->spot_reference . "]",
                message_to_client => $message_to_client,
            };
        }
    }

    return;
}

=head2 _validate_appconfig_age
 
We also want to guard against old appconfig.

=cut

sub _validate_appconfig_age {
    my $rev = BOM::Platform::Runtime->instance->app_config->current_revision;
    my $age = Time::HiRes::time - $rev;
    if ($age > 300) {
        warn "Config age is >300s - $age - is bin/update_appconfig_rev.pl running?\n";
        return {
            message           => "appconfig is out of date - age is now $age seconds",
            message_to_client => localize('Trading is currently suspended due to configuration update'),
        };
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
        my $end_of_trading = $underlying->calendar->closing_on($self->date_start);
        if ($end_of_trading and my $expiry_blackout = $underlying->eod_blackout_expiry) {
            push @periods, [$end_of_trading->minus_time_interval($expiry_blackout)->epoch, $end_of_trading->epoch];
        }
    } elsif ($self->expiry_daily and $underlying->market->equity and not $self->is_atm_bet) {
        my $start_of_period = BOM::System::Config::quants->{bet_limits}->{holiday_blackout_start};
        my $end_of_period   = BOM::System::Config::quants->{bet_limits}->{holiday_blackout_end};
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
    my $calendar   = $underlying->calendar;
    my $start      = $self->date_start;

    # We need to set sod_blackout_start for forex on Monday morning because otherwise, if there is no tick ,it will always take Friday's last tick and trigger the missing feed check
    if (my $sod = $calendar->opening_on($start)) {
        my $sod_blackout =
              ($underlying->sod_blackout_start) ? $underlying->sod_blackout_start
            : ($underlying->market->name eq 'forex' and $self->is_forward_starting and $start->day_of_week == 1) ? '10m'
            :                                                                                                      '';
        if ($sod_blackout) {
            push @periods, [$sod->epoch, $sod->plus_time_interval($sod_blackout)->epoch];
        }
    }

    my $end_of_trading = $calendar->closing_on($start);
    if ($end_of_trading) {
        if ($self->is_intraday) {
            my $eod_blackout =
                ($self->tick_expiry and ($underlying->resets_at_open or ($underlying->market->name eq 'forex' and $start->day_of_week == 5)))
                ? $self->max_tick_expiry_duration
                : $underlying->eod_blackout_start;
            push @periods, [$end_of_trading->minus_time_interval($eod_blackout)->epoch, $end_of_trading->epoch] if $eod_blackout;
        }

        if ($underlying->market->name eq 'indices' and not $self->is_intraday and not $self->is_atm_bet and $self->timeindays->amount <= 7) {
            push @periods, [$end_of_trading->minus_time_interval('1h')->epoch, $end_of_trading->epoch];
        }
    }

    return \@periods;
}

1;

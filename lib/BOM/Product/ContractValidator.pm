package BOM::Product::Contract;    ## no critic ( RequireFilenameMatchesPackage )

use strict;
use warnings;

use Time::HiRes;
use Date::Utility;
use List::Util qw(any first);

use LandingCompany::Registry;

use BOM::Config::Runtime;
use BOM::Config;
use BOM::Product::Static;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();
my %all_currencies = map { $_ => 1 } LandingCompany::Registry::all_currencies();

has disable_trading_at_quiet_period => (
    is      => 'ro',
    default => 1,
);

has [qw(require_manual_settlement waiting_for_settlement_tick)] => (
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

    my $valid = $self->_confirm_sell_validity($args);

    return $self->_report_validation_stats('sell', $valid);
}

sub _is_valid_to_settle {
    my $self = shift;

    my $message;
    # We have a separate conditions for tick expiry contracts because the settlement is based purely on ticks.
    # But, we also apply a rule to refund contract where it does not fulfill the settlement condition within 5 minutes
    # after the contract start time.
    if ($self->tick_expiry) {
        my $max_delay = $self->_max_tick_expiry_duration->seconds;
        if (not $self->entry_tick or $self->entry_tick->epoch - $self->date_start->epoch > $max_delay) {
            $message = 'Entry tick came after the maximum delay [' . $max_delay . ']';
        } elsif (not $self->exit_tick or $self->exit_tick->epoch - $self->date_start->epoch > $max_delay) {
            $message = 'Contract has started. Exit tick came after the maximum delay [' . $max_delay . ']';
        }
    } else {
        # The rule of thumb for intraday or multi-day contracts is if we have an entry and an exit tick in the correct order, we will settle the contract.
        if (not $self->entry_tick) {
            $message = 'entry tick is undefined';
        } elsif ($self->exit_tick and not $self->is_valid_exit_tick) {
            # There is pre-settlement exit tick which is not a valid exit tick for settlement
            $message = 'exit tick is inconsistent';
            $self->waiting_for_settlement_tick(1);
        } elsif ($self->entry_tick and $self->exit_tick and $self->entry_tick->epoch == $self->exit_tick->epoch) {
            $message = 'only one tick throughout contract period';
        } elsif ($self->entry_tick and $self->exit_tick and $self->entry_tick->epoch > $self->exit_tick->epoch) {
            $message = 'entry tick is after exit tick';
        } elsif ($self->is_path_dependent and not $self->ok_through_expiry) {
            $message = 'inconsistent close for period';
            $self->waiting_for_settlement_tick(1);
        }
    }

    # if no settlement fault message is set, then we are considered good to go!
    return 1 unless $message;

    $self->_add_error({
        message => $message,
        message_to_client =>
            ($self->waiting_for_settlement_tick ? [$ERROR_MAPPING->{WaitForContractSettlement}] : [$ERROR_MAPPING->{RefundBuyForMissingData}]),
    });

    $self->require_manual_settlement(1) unless $self->waiting_for_settlement_tick;

    return 0;
}

sub _confirm_sell_validity {
    my ($self, $args) = @_;

    # if the contract is sold (early close by client), then is_valid_to_sell is false
    if ($self->is_sold) {
        $self->_add_error({
            message           => 'Contract already sold',
            message_to_client => [$ERROR_MAPPING->{ContractAlreadySold}],
        });
        return 0;
    }

    # Because of indices where we get the official OHLC from the exchange, settlement time is always
    # 3 hours after the market close. Hence, there's a difference in date_expiry & date_settlement.
    #
    # This is not applicable for tick expiry contracts.
    if (not $self->tick_expiry and ($self->date_pricing->is_same_as($self->date_expiry) or $self->is_after_expiry) and not $self->is_after_settlement)
    {
        $self->_add_error({
            message           => 'waiting for settlement',
            message_to_client => [$ERROR_MAPPING->{WaitForContractSettlement}],
        });
        return 0;
    }

    # check for entry condition when contract has started for forward starting contracts
    if (    $self->starts_as_forward_starting
        and $self->entry_tick
        and ($self->date_start->epoch - $self->entry_tick->epoch > $self->underlying->max_suspend_trading_feed_delay->seconds))
    {
        # A start now contract will not be bought if we have missing feed.
        # We are doing the same thing for forward starting contracts.
        $self->_add_error({
            message           => 'entry tick is too old',
            message_to_client => [$ERROR_MAPPING->{RefundBuyForMissingData}],
        });
        $self->require_manual_settlement(1);

        return 0;
    }

    # check for valid settlement conditions if the contract has passed the settlement time.
    if ($self->is_after_settlement) {
        return $self->_is_valid_to_settle;
    }

    if (not $self->is_expired) {
        # if entry_tick is undefined (because it is the next tick), show the correct error message to client
        if (not($self->entry_tick or $self->starts_as_forward_starting)) {
            $self->_add_error({
                message           => "Waiting for entry tick [symbol: " . $self->underlying->symbol . "]",
                message_to_client => [$ERROR_MAPPING->{EntryTickMissing}],
            });
            return 0;
        } elsif (not $self->opposite_contract_for_sale->is_valid_to_buy($args)) {
            # Their errors are our errors, now!
            $self->_add_error($self->opposite_contract_for_sale->primary_validation_error);
            return 0;
        }
    }

    return 1;
}

sub _confirm_validity {
    my $self = shift;
    my $args = shift;

    # if there's initialization error, we will not proceed anyway.
    return 0 if $self->primary_validation_error;

    # Add any new validation methods here.
    # Looking them up can be too slow for pricing speed constraints.
    # This is the default list of validations.
    my @validation_methods = qw(_validate_offerings _validate_input_parameters _validate_start_and_expiry_date);
    push @validation_methods, qw(_validate_trading_times) unless $self->underlying->always_available;
    push @validation_methods, '_validate_barrier'         unless $args->{skip_barrier_validation};
    push @validation_methods, '_validate_barrier_type'    unless $self->for_sale;
    push @validation_methods, '_validate_feed';
    push @validation_methods, '_validate_price'           unless $self->skips_price_validation;
    push @validation_methods, '_validate_volsurface'      unless $self->volsurface->type eq 'flat';

    foreach my $method (@validation_methods) {
        if (my $err = $self->$method($args)) {
            $self->_add_error($err);
        }
        return 0 if ($self->primary_validation_error);
    }

    return 1;
}

# PRIVATE method.
# Validation methods.

# Is this underlying or contract is disabled/suspended from trading.
sub _validate_offerings {
    my $self = shift;

    # available payout currency
    unless ($all_currencies{$self->currency}) {
        BOM::Product::Exception->throw(
            error_code => 'InvalidPayoutCurrency',
            details    => {field => 'currency'},
        );
    }

    my $message_to_client = $self->for_sale ? [$ERROR_MAPPING->{ResaleNotOffered}] : [$ERROR_MAPPING->{TradeTemporarilyUnavailable}];

    if (BOM::Config::Runtime->instance->app_config->system->suspend->trading) {
        return {
            message           => 'All trading suspended on system',
            message_to_client => $message_to_client,
            details           => {},
        };
    }

    my $underlying    = $self->underlying;
    my $contract_code = $self->code;
    # check if trades are suspended on that claimtype
    my $suspend_contract_types = BOM::Config::Runtime->instance->app_config->quants->features->suspend_contract_types;
    if (@$suspend_contract_types and first { $contract_code eq $_ } @{$suspend_contract_types}) {
        return {
            message           => "Trading suspended for contract type [code: " . $contract_code . "]",
            message_to_client => $message_to_client,
            details           => {field => 'contract_type'},
        };
    }

    if (first { $_ eq $underlying->symbol } @{BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_trades}) {
        return {
            message           => "Underlying trades suspended [symbol: " . $underlying->symbol . "]",
            message_to_client => $message_to_client,
            details           => {field => 'symbol'},
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
            details           => {field => 'symbol'},
        };
    } elsif ($self->trading_calendar->is_open_at($underlying->exchange, $self->date_pricing)
        && $self->date_pricing->epoch - $self->maximum_feed_delay_seconds > $self->current_tick->epoch)
    {
        return {
            message           => "Quote too old [symbol: " . $underlying->symbol . "]",
            message_to_client => [$ERROR_MAPPING->{OldMarketData}],
            details           => {field => 'symbol'},
        };
    }

    return;
}

sub _validate_price {
    my $self = shift;

    return if $self->for_sale;

    # Price validation needs updated P::C attributes
    $self->price_calculator->theo_probability($self->theo_probability);
    $self->price_calculator->commission_markup($self->commission_markup);
    $self->price_calculator->commission_from_stake($self->commission_from_stake);
    $self->price_calculator->staking_limits($self->staking_limits);
    my $res = $self->price_calculator->validate_price;
    if ($res && exists $res->{error_code}) {
        my $details = $res->{error_details} || [];
        $res = {
            zero_stake => sub {
                my ($details) = @_;
                return {
                    message           => "Empty or zero stake [stake: " . $details->[0] . "]",
                    message_to_client => [$ERROR_MAPPING->{InvalidStake}],
                    details           => {field => 'amount'},
                };
            },
            stake_outside_range => sub {
                my ($details) = @_;
                my $params = [$details->[0], $details->[1], $details->[2]];
                return {
                    message           => 'stake is not within limits ' . "[stake: " . $details->[0] . "] " . "[min: " . $details->[1] . "] ",
                    message_to_client => [$ERROR_MAPPING->{StakeLimits}, @$params],
                    details           => {field => 'amount'},
                };
            },
            payout_outside_range => sub {
                my ($details) = @_;
                my $params = [$details->[0], $details->[1], $details->[2]];
                return {
                    message => 'payout amount outside acceptable range ' . "[given: " . $details->[0] . "] " . "[max: " . $details->[1] . "]",
                    message_to_client => [$ERROR_MAPPING->{PayoutLimits}, @$params],
                    details => {field => 'amount'},
                };
            },
            payout_too_many_places => sub {
                my ($details) = @_;
                return {
                    message => 'payout amount has too many decimal places ' . "[permitted: " . $details->[0] . "] [payout: " . $details->[1] . "]",
                    message_to_client => [$ERROR_MAPPING->{IncorrectPayoutDecimals}, $details->[0]],
                    details => {field => 'amount'},
                };
            },
            stake_too_many_places => sub {
                my ($details) = @_;
                return {
                    message => 'stake amount has too many decimal places ' . "[permitted: " . $details->[0] . "] [payout: " . $details->[1] . "]",
                    message_to_client => [$ERROR_MAPPING->{IncorrectStakeDecimals}, $details->[0]],
                    details => {field => 'amount'},
                };
            },
            stake_same_as_payout => sub {
                my ($details) = @_;
                return {
                    message           => 'stake same as payout',
                    message_to_client => [$ERROR_MAPPING->{NoReturn}],
                    details           => {},
                };
            },
        }->{$res->{error_code}}->($details);
    }
    return $res;
}

sub _validate_barrier_type {
    my $self = shift;

    return if $self->tick_expiry;

    return if ((not $self->two_barriers) and defined $self->barrier and $self->supplied_barrier_type eq 'digit');

    # The barrier for atm bet is always SOP which is relative
    return if ($self->is_atm_bet and defined $self->barrier and $self->barrier->barrier_type eq 'relative');

    # intraday non ATM barrier could be absolute or relative
    return if $self->is_intraday;

    foreach my $barrier ($self->two_barriers ? ('high_barrier', 'low_barrier') : ('barrier')) {
        # For multiday, the barrier must be absolute.
        # For intraday, the barrier can be absolute or relative.
        if (defined $self->$barrier and $self->$barrier->barrier_type ne 'absolute') {

            my %field_for = (
                'low_barrier'  => 'barrier2',
                'high_barrier' => 'barrier',
                'barrier'      => 'barrier',
            );
            return {
                message           => 'barrier should be absolute for multi-day contracts',
                message_to_client => [$ERROR_MAPPING->{NeedAbsoluteBarrier}],
                details           => {field => $field_for{$barrier}},
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
            details           => {field => defined($self->duration) ? 'duration' : 'date_expiry'},
        };
    } elsif ($epoch_expiry < $epoch_start) {
        return {
            message           => 'Start must be before expiry ' . "[start: " . $epoch_start . "] " . "[expiry: " . $epoch_expiry . "]",
            message_to_client => [$ERROR_MAPPING->{PastExpiryTime}],
            details           => {field => 'date_expiry'},
        };
    } elsif (not $self->for_sale and $epoch_start < $when_epoch) {
        return {
            message           => 'starts in the past ' . "[start: " . $epoch_start . "] " . "[now: " . $when_epoch . "]",
            message_to_client => [$ERROR_MAPPING->{PastStartTime}],
            details           => {field => 'date_start'},
        };
    } elsif (not $self->is_forward_starting and $epoch_start > $when_epoch) {
        return {
            message           => "Forward time for non-forward-starting contract type [code: " . $self->code . "]",
            message_to_client => [$ERROR_MAPPING->{FutureStartTime}],
            details           => {field => 'date_start'},
        };
    } elsif ($self->is_forward_starting and not $self->for_sale) {
        # Intraday cannot be bought in the 5 mins before the bet starts, unless we've built it for that purpose.
        my $fs_blackout_seconds = 300;
        if ($epoch_start < $when_epoch + $fs_blackout_seconds) {
            return {
                message           => "forward-starting blackout [blackout: " . $fs_blackout_seconds . "s]",
                message_to_client => [$ERROR_MAPPING->{ForwardStartTime}],
                details           => {field => 'date_start'},
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
        if ($closing and not $date_expiry->is_same_as($closing) and not $self->for_sale) {
            return {
                message => 'daily expiry must expire at close '
                    . "[expiry: "
                    . $date_expiry->datetime . "] "
                    . "[underlying_symbol: "
                    . $self->underlying->symbol . "]",
                message_to_client => [$ERROR_MAPPING->{TradingDayEndExpiry}],
                details           => {field => defined($self->duration) ? 'duration' : 'date_expiry'},
            };
        }
    }

    if ($self->category_code eq 'reset' and not $self->for_sale) {
        if ($self->supplied_barrier ne 'S0P') {
            return {
                message           => 'Non atm barrier for reset contract is not allowed.',
                message_to_client => [$ERROR_MAPPING->{ResetBarrierError}],
                details           => {field => 'barrier'},
            };
        }

        if ($self->fixed_expiry) {
            return {
                message           => 'Fixed expiry for reset contract is not allowed.',
                message_to_client => [$ERROR_MAPPING->{ResetFixedExpiryError}],
                details           => {field => 'date_expiry'},
            };
        }
    }

    return;
}

sub _validate_trading_times {
    my $self = shift;
    my $args = shift;

    my $underlying           = $self->underlying;
    my $exchange             = $underlying->exchange;
    my $calendar             = $self->trading_calendar;
    my $date_expiry          = $self->date_expiry;
    my $date_start           = $self->date_start;
    my $synthetic_index_flag = 1;
    my (@markets, $lc);

    if (not($calendar->trades_on($exchange, $date_start) and $calendar->is_open_at($exchange, $date_start))) {
        if ($args->{landing_company}) {
            $lc = LandingCompany::Registry::get($args->{landing_company});
            if ($lc and $args->{country_code}) {
                @markets = $lc->basic_offerings_for_country($args->{country_code}, BOM::Config::Runtime->instance->get_offerings_config())
                    ->values_for_key('market');
            } else {
                @markets = @{$lc->legal_allowed_markets};
            }
            $synthetic_index_flag = any { $_ eq 'synthetic_index' } @markets;
        }
        my $error_code;
        if ($synthetic_index_flag) {
            $error_code = $self->is_forward_starting ? 'MarketNotOpenTryVolatility' : 'MarketIsClosedTryVolatility';
        } else {
            $error_code = $self->is_forward_starting ? 'MarketNotOpen' : 'MarketIsClosed';
        }

        return {
            message => 'underlying is closed at start ' . "[symbol: " . $underlying->symbol . "] " . "[start: " . $date_start->datetime . "]",
            message_to_client => [$ERROR_MAPPING->{$error_code}],
            details           => {field => $self->is_forward_starting ? 'date_start' : 'symbol'},
        };
    } elsif (not $calendar->trades_on($exchange, $date_expiry)) {
        return ({
            message           => "Exchange is closed on expiry date [expiry: " . $date_expiry->date . "]",
            message_to_client => [$ERROR_MAPPING->{TradingDayExpiry}],
            details           => {field => defined($self->duration) ? 'duration' : 'date_expiry'},
        });
    }

    if ($self->is_intraday) {
        if (not $calendar->is_open_at($exchange, $date_expiry)) {
            return {
                message => 'underlying closed at expiry ' . "[symbol: " . $underlying->symbol . "] " . "[expiry: " . $date_expiry->datetime . "]",
                message_to_client => [$ERROR_MAPPING->{TradingHoursExpiry}],
                details           => {field => defined($self->duration) ? 'duration' : 'date_expiry'},
            };
        } elsif ($underlying->intradays_must_be_same_day and $calendar->closing_on($exchange, $date_start)->epoch < $date_expiry->epoch) {
            return {
                message           => "Intraday duration must expire on same day [symbol: " . $underlying->symbol . "]",
                message_to_client => [$ERROR_MAPPING->{SameTradingDayExpiry}],
                details           => {field => defined($self->duration) ? 'duration' : 'date_expiry'},
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
                $self->for_sale ? () : (details => {field => defined($self->duration) ? 'duration' : 'date_expiry'})};
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

=head2 date_start_forward_blackouts

forward starting contracts cannot be bought at the certain period

=cut

has date_start_forward_blackouts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_date_start_forward_blackouts {
    my $self = shift;

    return [] if $self->market->name ne 'forex';
    return [] if not $self->is_forward_starting;
    return [] if not $self->is_intraday;

    my $today = $self->effective_start->truncate_to_day;

    return [[$today->plus_time_interval('21h')->epoch, $today->plus_time_interval('23h59m59s')->epoch]];
}

sub _validate_start_and_expiry_date {
    my $self = shift;

    # random_index will not have any blackout period unless this rule were to change in the future.
    # returning early here!
    # DO NOT change this to $self->market->name eq 'synthetic_index' because we have blackout period for random_daily submarket
    # This is done for buy optimisation
    return if $self->underlying->submarket->name eq 'random_index';

    # Currently, there's a bug in our system for contract ending at the start of day (00 GMT). We made the fix for offical OHLC handling
    # that causes this bug. Since we are removing indices and OTC indices do not settle on official OHLC anymore, we will disable
    # contracts expiring at the start of day for now. We will re-enable it again once we remove indices from our offerings.
    if ($self->date_expiry->epoch % 86400 == 0) {
        return {
            message           => 'Cannot expire at end of day',
            message_to_client => [$ERROR_MAPPING->{InvalidExpiryTime}],
            details           => {field => defined($self->duration) ? 'duration' : 'date_expiry'},
        };
    }

    my $start_epoch = $self->effective_start->epoch;
    my $end_epoch   = $self->date_expiry->epoch;
    #Note: Please don't change the message for expiry blackout (specifically, the 'expire' word) unless you have
    #updated the check in this method which updates end_epoch
    my @blackout_checks = (
        [[$start_epoch], $self->date_start_blackouts,  'TradingNotAvailable'],
        [[$end_epoch],   $self->date_expiry_blackouts, 'ContractExpiryNotAllowed'],
        [[$start_epoch, $end_epoch], $self->market_risk_blackouts,        'TradingNotAvailable'],
        [[$start_epoch, $end_epoch], $self->forward_blackouts,            'TradingNotAvailable'],
        [[$start_epoch, $end_epoch], $self->date_start_forward_blackouts, 'TradingNotAvailable'],
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
                [$start_epoch], [[map { Date::Utility->new($pricing_date)->plus_time_interval($_)->epoch } qw(21h 23h59m59s)]],
                'TradingSuspendedSpecificHours'
                ];
        }
    }

    foreach my $blackout (@blackout_checks) {
        my ($epochs, $periods, $error_code) = @{$blackout}[0 .. 2];
        my @args = ();
        foreach my $period (@$periods) {
            my $start_epoch = $period->[0];
            my $end_epoch   = $period->[1];

            $end_epoch++ if ($error_code eq 'ContractExpiryNotAllowed');

            if (my $epoch = first { $_ >= $start_epoch and $_ < $end_epoch } @$epochs) {
                my $start = Date::Utility->new($period->[0]);
                my $end   = Date::Utility->new($period->[1]);
                if ($start->day_of_year == $end->day_of_year) {
                    push @args, ($start->time_hhmmss, $end->time_hhmmss);
                } else {
                    push @args, ($start->date, $end->date);
                }

                my $field = defined($self->duration) ? 'duration' : 'date_expiry';
                $field = 'date_start' if $error_code eq 'TradingNotAvailable' && $epoch == $epochs->[0];

                return {
                    message => 'blackout period '
                        . "[symbol: "
                        . $self->underlying->symbol . "] "
                        . "[from: "
                        . $period->[0] . "] " . "[to: "
                        . $period->[1] . "]",
                    message_to_client => [$ERROR_MAPPING->{$error_code}, @args],
                    details => {field => $field},
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
            details           => {field => 'symbol'},
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
            details           => {field => 'symbol'},
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
                details           => {field => 'symbol'},
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
        my $start_of_period = BOM::Config::quants()->{bet_limits}->{holiday_blackout_start};
        my $end_of_period   = BOM::Config::quants()->{bet_limits}->{holiday_blackout_end};
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

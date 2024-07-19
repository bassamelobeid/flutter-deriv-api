package BOM::Contract::Pricer;

use v5.26;
use warnings;

use Format::Util::Numbers qw(formatnumber roundcommon);
use JSON::MaybeXS;
use List::Util qw(max);

our @EXPORT_OK = qw( price_contract );

=head2 calc_ask_price_detailed

Calculate ask price for the contract and return a hashref with all relevant
details including: longcode, payout, ask price, spot time, start and expiry
dates and other contract specific parameters. Accepts two arguments: the
contract and a hashref containing following optional parameters:

=over 4

=item update -- produce update message, that might skip some details

=back

=cut

sub calc_ask_price_detailed {
    my ($class, $contract, $args) = @_;
    my $update = $args->{update};

    # the code below should be refactored not to use inner_contract or any
    # details depending on a specific contract type
    my $inner = $contract->inner_contract;

    my $ask_price = formatnumber('price', $inner->currency, $inner->ask_price);
    my $response  = {
        longcode            => $inner->longcode,
        payout              => $inner->payout,
        ask_price           => $ask_price,
        display_value       => $ask_price,
        spot_time           => $inner->current_tick->epoch,
        date_start          => $inner->date_start->epoch,
        date_expiry         => $inner->date_expiry->epoch,
        contract_parameters => {
            app_markup_percentage => $inner->app_markup_percentage,
            ($inner->is_binary) ? (staking_limits => $inner->staking_limits) : (),    #staking limits only apply to binary
            deep_otm_threshold    => $inner->otm_threshold,
            base_commission       => $inner->base_commission,
            min_commission_amount => $inner->min_commission_amount,
        },
        skip_streaming => $inner->skip_streaming,
    };

    if (not $inner->is_binary) {
        $response->{contract_parameters}->{multiplier} = $inner->multiplier
            if $inner->can('multiplier')
            and not $inner->user_defined_multiplier;
        $response->{contract_parameters}->{maximum_ask_price} = $inner->maximum_ask_price if $inner->can('maximum_ask_price');
    }

    if ($inner->require_price_adjustment and $update) {
        if ($inner->is_binary) {
            $response->{theo_probability} = $inner->theo_probability->amount;
        } else {
            $response->{theo_price} = $inner->theo_price;
        }
    }

    if ($inner->underlying->feed_license eq 'realtime') {
        $response->{spot} = $inner->current_spot;
    }

    $response->{multiplier} = $inner->multiplier if $inner->can('multiplier');

    if ($inner->category_code eq 'vanilla') {
        $response->{min_stake}                   = $inner->min_stake;
        $response->{max_stake}                   = $inner->max_stake;
        $response->{display_number_of_contracts} = $inner->number_of_contracts;
        $response->{barrier_choices}             = $inner->strike_price_choices;
    }

    if ($inner->category_code eq 'multiplier') {
        my $display = $inner->available_orders_for_display;
        $response->{limit_order}      = $display;
        $response->{commission}       = $inner->commission_amount;    # commission in payout currency amount
        $response->{contract_details} = {
            minimum_stake => $inner->min_stake,
            maximum_stake => $inner->max_stake,
        };

        if ($inner->cancellation) {
            $response->{cancellation} = {
                ask_price   => $inner->cancellation_price,
                date_expiry => $inner->cancellation_expiry->epoch,
            };
        }
    }

    if ($inner->category_code eq 'accumulator') {
        if ($inner->take_profit) {
            $response->{limit_order} = {
                'take_profit' => {
                    'display_name' => 'Take profit',
                    'order_date'   => $inner->take_profit->{date}->epoch,
                    'order_amount' => $inner->take_profit->{amount}}};
        }

        my $redis          = BOM::Config::Redis::redis_replicated_read();
        my $underlying_key = join('::', $inner->underlying->symbol, 'growth_rate_' . $inner->growth_rate);
        my $stat_key       = join('::', 'accumulator', 'stat_history', $underlying_key);

        #if the request is coming from Websocket we should return all data(100 numbers) to build the stat chart.
        #after that(when the request is coming from pricer) we only need to return the last value to update it

        my ($ticks_stayed_in, $last_tick_processed_json, @res, $last_tick_processed);

        if ($update) {
            $redis->execute('multi');
            $redis->execute('lrange', $stat_key, -1, -1);
            $redis->execute('hget', "accumulator::previous_tick_barrier_status", $underlying_key);
            @res = $redis->execute('exec');
        } else {
            $redis->execute('multi');
            $redis->execute('lrange', $stat_key, 0, -1);
            $redis->execute('hget', "accumulator::previous_tick_barrier_status", $underlying_key);
            @res = $redis->execute('exec');
        }

        if (@res) {
            $ticks_stayed_in          = $res[0][0];
            $last_tick_processed_json = $res[0][1];
        }

        $last_tick_processed = decode_json($last_tick_processed_json) if $last_tick_processed_json;

        if ($last_tick_processed && @$ticks_stayed_in) {
            # ticks_stayed_in does not include the latest tick yet, we
            # need to calculate what it should be if we include the
            # latest tick
            if ($last_tick_processed->{tick_epoch} < $inner->current_tick->epoch) {
                if (    $inner->current_spot > $last_tick_processed->{low_barrier}
                    and $inner->current_spot < $last_tick_processed->{high_barrier})
                {
                    # the latest tick stayed in
                    $ticks_stayed_in->[-1]++;
                } else {
                    # the latest tick got out
                    if ($update) {
                        $ticks_stayed_in->[-1] = 0;
                    } else {
                        push @{$ticks_stayed_in}, 0;
                        pop @{$ticks_stayed_in} if @{$ticks_stayed_in} > 100;
                    }
                }
            }
        }

        #barriers in PP should be calculated based on the current tick
        my $high_barrier = $inner->current_spot_high_barrier;
        my $low_barrier  = $inner->current_spot_low_barrier;

        $response->{contract_details} = {
            'maximum_payout'               => $inner->max_payout,
            'minimum_stake'                => $inner->min_stake,
            'maximum_stake'                => $inner->max_stake,
            'maximum_ticks'                => $inner->max_duration,
            'tick_size_barrier'            => $inner->tick_size_barrier,
            'tick_size_barrier_percentage' => $inner->tick_size_barrier_percentage,
            'high_barrier'                 => $high_barrier,
            'low_barrier'                  => $low_barrier,
            'barrier_spot_distance'        => $inner->barrier_spot_distance
        };
        $response->{contract_details}->{ticks_stayed_in} = $ticks_stayed_in                   if @$ticks_stayed_in;
        $response->{contract_details}->{last_tick_epoch} = $last_tick_processed->{tick_epoch} if $last_tick_processed;
    }

    if ($inner->category_code eq 'turbos') {
        if ($inner->take_profit) {
            $response->{limit_order} = {
                'take_profit' => {
                    'display_name' => 'Take profit',
                    'order_date'   => $inner->take_profit->{date}->epoch,
                    'order_amount' => $inner->take_profit->{amount}}};
        }

        # handling response for payout_per_points and barriers for turbos
        # barrier choices should be removed once we switched turbos to payout_per_point
        $inner->{has_user_defined_barrier}
            ? ($response->{barrier_choices} = $inner->strike_price_choices)
            : ($response->{payout_choices} = $inner->payout_choices);

        $response->{display_number_of_contracts} = $inner->number_of_contracts;
        $response->{min_stake}                   = $inner->min_stake;
        $response->{max_stake}                   = $inner->max_stake;
    }

    if (($inner->two_barriers) and ($inner->category_code ne 'accumulator')) {
        # accumulator has its own logic
        $response->{contract_details}->{high_barrier} = $inner->high_barrier->as_absolute;
        $response->{contract_details}->{low_barrier}  = $inner->low_barrier->as_absolute;
    } elsif ($inner->can('barrier') and (defined $inner->barrier)) {
        # Contracts without "barrier" attribute is skipped
        $response->{contract_details}->{barrier} = $inner->barrier->as_absolute;
    }
    # On websocket, we are setting 'basis' to payout and 'amount' to 1000 to increase the collission rate.
    # This logic shouldn't be in websocket since it is business logic.
    unless ($update) {
        # To override multiplier or callputspread contracts (non-binary) just does not make any sense because
        # the ask_price is defined by the user and the output of limit order (take profit or stop out),
        # is dependent of the stake and multiplier provided by the client.
        # There is no probability calculation involved. Hence, not optimising anything.
        # Since vanilla and turbos have no payout, adding it here as well
        $response->{skip_basis_override} = 1
            if $contract->inner_contract->code =~
            /^(MULTUP|MULTDOWN|CALLSPREAD|PUTSPREAD|ACCU|VANILLALONGCALL|VANILLALONGPUT|TURBOSLONG|TURBOSSHORT)$/;
    }

    return $response;
}

=head2 calc_bid_price_detailed

Calculate bid price for the contract and return a hashref with all the relevant
details.  Accepts two arguments: the contract and a hashref containing the
following parameters:

=over 4

=item is_sold  Boolean  Whether the contract is sold or not.

=item is_expired  Boolean  Whether the contract is expired or not.

=item sell_price   Numeric Price at which contract was sold, only available
when contract has been sold.

=item sell_time   Integer Epoch time of when the contract was sold (only
present for contracts already sold).

=back

Returns a contract proposal response as a  Hashref

=cut

my @spot_list = qw(entry_tick entry_spot exit_tick sell_spot current_spot);

sub calc_bid_price_detailed {
    my ($class, $contract, $params) = @_;
    my $inner              = $contract->inner_contract;
    my $is_valid_to_settle = $inner->is_settleable;
    my $underlying         = $inner->underlying;
    my $valid_updates      = $inner->make_is_valid_to_update();

    my $response = {
        barrier_count       => $inner->two_barriers ? 2 : 1,
        bid_price           => formatnumber('price', $inner->currency, $inner->bid_price),
        contract_type       => $inner->code,
        currency            => $inner->currency,
        current_spot_time   => 0 + $inner->current_tick->epoch,
        date_expiry         => 0 + $inner->date_expiry->epoch,
        date_settlement     => 0 + $inner->date_settlement->epoch,
        date_start          => 0 + $inner->date_start->epoch,
        display_name        => $underlying->display_name,
        expiry_time         => $inner->date_expiry->epoch,
        is_expired          => $inner->is_expired,
        is_forward_starting => $inner->starts_as_forward_starting,
        is_intraday         => $inner->is_intraday,
        is_path_dependent   => $inner->is_path_dependent,
        is_settleable       => $is_valid_to_settle,
        is_valid_to_cancel  => $inner->is_valid_to_cancel,
        longcode            => $inner->longcode,
        shortcode           => $inner->shortcode,
        underlying          => $underlying->symbol,
    };

    $response->{current_spot}       = $inner->current_spot if $underlying->feed_license eq 'realtime';
    $response->{is_valid_to_update} = $valid_updates       if $valid_updates;
    $response->{multiplier}         = $inner->multiplier   if $inner->can('multiplier');
    $response->{tick_count}         = $inner->tick_count   if $inner->expiry_type eq 'tick';

    if (!$inner->uses_barrier) {
        $response->{barrier_count} = 0;
        $response->{barrier}       = undef;
    }

    if ($inner->reset_spot) {
        $response->{reset_time}    = 0 + $inner->reset_spot->epoch;
        $response->{reset_barrier} = $underlying->pipsized_value($inner->reset_spot->quote);
    }

    if ($inner->is_binary) {
        $response->{payout} = $inner->payout;
    } elsif ($inner->can('maximum_payout')) {
        $response->{payout} = $inner->maximum_payout;
    }

    if ($params->{is_sold} and $params->{is_expired}) {
        # here sell_price is used to parse the status of contracts that settled from Back Office
        # For non binary (except accumulator), there is no concept of won or lost, hence will return empty status if it is already expired and sold
        $response->{status} = undef;
        if ($inner->is_binary) {
            $response->{status} = ($params->{sell_price} == $inner->payout ? "won" : "lost");
        }
    } elsif ($params->{is_sold} and not $params->{is_expired}) {
        $response->{status} = 'sold';
    } else {    # not sold
        $response->{status} = 'open';
    }

    # overwrite the above status if contract is cancelled
    $response->{status} = 'cancelled' if $inner->is_cancelled;

    if ($inner->entry_spot) {
        my $entry_spot = $underlying->pipsized_value($inner->entry_spot);
        $response->{entry_tick}      = $entry_spot;
        $response->{entry_spot}      = $entry_spot;
        $response->{entry_tick_time} = 0 + $inner->entry_spot_epoch;
    }

    if ($inner->two_barriers and $inner->high_barrier) {
        # supplied_type 'difference' and 'relative' will need entry spot to calculate absolute barrier value
        if ($inner->high_barrier->supplied_type eq 'absolute' or $inner->entry_spot) {
            $response->{high_barrier} = $inner->high_barrier->as_absolute;
            $response->{low_barrier}  = $inner->low_barrier->as_absolute;
        }
    } elsif ($inner->can('barrier') and $inner->barrier) {
        if ($inner->barrier->supplied_type eq 'absolute' or $inner->barrier->supplied_type eq 'digit') {
            $response->{barrier} = $inner->barrier->as_absolute;
        } elsif ($inner->entry_spot) {
            $response->{barrier} = $inner->barrier->as_absolute;
        }
    }

    # for multiplier, we want to return the orders and insurance details.
    if ($inner->category_code eq 'multiplier') {
        # If the caller is not from price daemon, we need:
        # 1. sorted orders as array reference ($contract->available_orders) for PRICER_ARGS
        # 2. available order for display in the websocket api response ($contract->available_orders_for_display)
        $response->{limit_order} = $inner->available_orders_for_display;
        # commission in payout currency amount
        $response->{commission} = $inner->commission_amount;
        # deal cancellation
        if ($inner->cancellation) {
            $response->{cancellation} = {
                ask_price   => $inner->cancellation_price,
                date_expiry => $inner->cancellation_expiry->epoch,
            };
        }
    }

    # for accumulator, we want to return maximum_ticks and growth_rate and limit_order.
    if ($inner->category_code eq 'accumulator') {
        if ($inner->take_profit) {
            $response->{limit_order} = {
                'take_profit' => {
                    'display_name' => 'Take profit',
                    'order_date'   => $inner->take_profit->{date}->epoch,
                    'order_amount' => $inner->take_profit->{amount}}};
        }
        $response->{growth_rate}               = $inner->growth_rate;
        $response->{tick_count}                = $inner->max_duration;
        $response->{tick_passed}               = $inner->tick_count_after_entry;
        $response->{high_barrier}              = $inner->display_high_barrier if $inner->display_high_barrier;
        $response->{low_barrier}               = $inner->display_low_barrier  if $inner->display_low_barrier;
        $response->{current_spot_high_barrier} = $inner->current_spot_high_barrier;
        $response->{current_spot_low_barrier}  = $inner->current_spot_low_barrier;
        $response->{barrier_spot_distance}     = $inner->barrier_spot_distance;

        #in the first few ticks of the contract bid_price will be less than stake
        #but we don't want to show that to users
        $response->{bid_price} = max($response->{bid_price}, $inner->_user_input_stake) unless $inner->is_expired;

        #status of accumulator is determined differently from other non-binary contracts
        if ($params->{is_sold} and $params->{is_expired}) {
            $response->{status} = ($inner->pnl >= 0 ? "won" : "lost");
        } elsif ($params->{is_sold} and not $params->{is_expired}) {
            #user can only sell the contract if pnl > 0, so it will considered as a 'win'
            $response->{status} = 'won';
        } else {    # not sold
            $response->{status} = 'open';
        }
    }

    if ($inner->category_code eq 'turbos') {
        if ($inner->take_profit) {
            $response->{limit_order} = {
                'take_profit' => {
                    'display_name' => 'Take profit',
                    'order_date'   => $inner->take_profit->{date}->epoch,
                    'order_amount' => $inner->take_profit->{amount}}};
        }
        $response->{barrier}                     = $inner->display_barrier;
        $response->{display_number_of_contracts} = $inner->number_of_contracts;

        # status of turbos is determined differently from other non-binary contracts
        if ($params->{is_sold} and $params->{is_expired}) {
            $response->{status} = ($inner->pnl >= 0 ? "won" : "lost");
        } elsif ($params->{is_sold} and not $params->{is_expired}) {
            $response->{status} = 'sold';
        } else {
            $response->{status} = 'open';
        }
    }

    if ($inner->category_code eq 'vanilla') {
        $response->{display_number_of_contracts} = $inner->number_of_contracts;
    }

    if (    $inner->exit_tick
        and $inner->is_valid_exit_tick
        and $inner->is_after_settlement)
    {
        $response->{exit_tick}      = $inner->underlying->pipsized_value($inner->exit_tick->quote);
        $response->{exit_tick_time} = 0 + $inner->exit_tick->epoch;
    }

    if ($is_valid_to_settle || $inner->is_sold) {
        $response->{audit_details} = $inner->audit_details($params->{sell_time});
    }

    # sell_spot and sell_spot_time are updated if the contract is sold
    # or when the contract is expired.
    #exit_tick to be returned on these scenario:
    # - sell back early (tick at sell time)
    # - hit tick for an American contract
    # - latest tick at the expiry time of a European contract.
    # TODO: Planning to phase out sell_spot in the next API version.

    my $contract_close_tick;
    # contract expire before the expiry time
    if ($params->{sell_time} and $params->{sell_time} < $inner->date_expiry->epoch) {
        if (    $inner->is_path_dependent
            and $inner->close_tick
            and $inner->close_tick->epoch <= $params->{sell_time})
        {
            $contract_close_tick = $inner->close_tick;
        }

        if ((!$inner->is_path_dependent) and ($inner->can('close_tick'))) {
            # using close_tick if the non path dependent contract has the method defined
            # since tick_at is not reliable for sell at market contracts
            $contract_close_tick = $inner->close_tick;
        }

        # client sold early
        $contract_close_tick = $inner->underlying->tick_at($params->{sell_time}, {allow_inconsistent => 1})
            unless defined $contract_close_tick;
    } elsif ($inner->is_expired) {
        # it could be that the contract is not sold until/after expiry for path dependent
        $contract_close_tick = $inner->close_tick if $inner->is_path_dependent;
        $contract_close_tick = $inner->exit_tick  if not $contract_close_tick and $inner->exit_tick and $inner->is_valid_exit_tick;
    }

    # if the contract is still open, $contract_close_tick will be undefined
    if (defined $contract_close_tick) {
        foreach my $key ($params->{is_sold} ? qw(sell_spot exit_tick) : qw(exit_tick)) {
            $response->{$key} = $inner->underlying->pipsized_value($contract_close_tick->quote);
            $response->{$key . '_time'} = 0 + $contract_close_tick->epoch;
        }
    }

    if ($inner->tick_expiry) {

        $response->{tick_stream} = $inner->tick_stream;

        if ($inner->category->code eq 'highlowticks' and $inner->selected_tick) {
            my $selected_tick = $inner->selected_tick;
            $response->{selected_tick} = 0 + $selected_tick;

            if ($inner->supplied_barrier) {
                $response->{selected_spot} = 0 + $inner->supplied_barrier;
            }
        }
    }

    $response->{$_ . '_display_value'} = $inner->underlying->pipsized_value($response->{$_}) for (grep { defined $response->{$_} } @spot_list);
    # makes sure they are numbers
    $response->{$_} += 0 for (grep { defined $response->{$_} } @spot_list);

    return $response;
}

1;

package BOM::Contract::Pricer;

use v5.26;
use warnings;

use Format::Util::Numbers qw(formatnumber roundcommon);
use JSON::MaybeXS;

our @EXPORT_OK = qw( price_contract );

=head2 calc_ask_price_detailed

Calculate ask price for the contract and return a hashref with all relevant
details including: longcode, payout, ask price, spot time, start and expiry
dates and other contract specific parameters.

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
        $response->{number_of_contracts}         = $inner->number_of_contracts;
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
        my $ticks_stayed_in =
              $update
            ? $redis->lrange($stat_key, -1, -1)
            : $redis->lrange($stat_key, 0,  -1);

        my $last_tick_processed_json = $redis->hget("accumulator::previous_tick_barrier_status", $underlying_key);
        my $last_tick_processed;
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
        $response->{number_of_contracts}         = $inner->number_of_contracts;
        $response->{display_number_of_contracts} = $inner->number_of_contracts;
        $response->{barrier_choices}             = $inner->strike_price_choices;
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

1;

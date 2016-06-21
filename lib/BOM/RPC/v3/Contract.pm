package BOM::RPC::v3::Contract;

use strict;
use warnings;

use Try::Tiny;
use List::MoreUtils qw(none);

use BOM::RPC::v3::Utility;
use BOM::Market::Underlying;
use BOM::Platform::Context qw (localize request);
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Contract::Helper;
use Format::Util::Numbers qw(roundnear);
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_timing);

sub validate_symbol {
    my $symbol    = shift;
    my @offerings = get_offerings_with_filter('underlying_symbol');
    if (!$symbol || none { $symbol eq $_ } @offerings) {
        return {
            error => {
                code    => 'InvalidSymbol',
                message => "Symbol [_1] invalid",
                params  => [$symbol],
            }};
    }
    return;
}

sub validate_license {
    my $symbol = shift;
    my $u      = BOM::Market::Underlying->new($symbol);

    if ($u->feed_license ne 'realtime') {
        return {
            error => {
                code    => 'NoRealtimeQuotes',
                message => "Realtime quotes not available for [_1]",
                params  => [$symbol],
            }};
    }
    return;
}

sub validate_underlying {
    my $symbol = shift;

    my $response = validate_symbol($symbol);
    return $response if $response;

    $response = validate_license($symbol);
    return $response if $response;

    return {status => 1};
}

sub prepare_ask {
    my $p1 = shift;
    my %p2 = %$p1;

    $p2{date_start} //= 0;
    if ($p2{date_expiry}) {
        $p2{fixed_expiry} //= 1;
    }

    if (defined $p2{barrier} && defined $p2{barrier2}) {
        $p2{low_barrier}  = delete $p2{barrier2};
        $p2{high_barrier} = delete $p2{barrier};
    } elsif ($p1->{contract_type} !~ /^(SPREAD|ASIAN|DIGITEVEN|DIGITODD)/) {
        $p2{barrier} //= 'S0P';
        delete $p2{barrier2};
    }

    $p2{underlying}  = delete $p2{symbol};
    $p2{bet_type}    = delete $p2{contract_type};
    $p2{amount_type} = delete $p2{basis} if exists $p2{basis};
    if ($p2{duration} and not exists $p2{date_expiry}) {
        $p2{duration} .= delete $p2{duration_unit};
    }

    return \%p2;
}

sub _get_ask {
    my $p2 = shift;

    my $response;
    try {
        my $tv       = [Time::HiRes::gettimeofday];
        my $contract = produce_contract({%$p2});

        if (!$contract->is_valid_to_buy) {
            my ($message_to_client, $code);

            if (my $pve = $contract->primary_validation_error) {
                $message_to_client = $pve->message_to_client;
                $code              = "ContractBuyValidationError";
            } else {
                $message_to_client = localize("Cannot validate contract");
                $code              = "ContractValidationError";
            }
            $response = BOM::RPC::v3::Utility::create_error({
                    message_to_client => $message_to_client,
                    code              => $code,
                    details           => {
                        longcode      => $contract->longcode,
                        display_value => ($contract->is_spread ? $contract->buy_level : sprintf('%.2f', $contract->ask_price)),
                        payout => sprintf('%.2f', $contract->payout),
                    },
                });
        } else {
            my $ask_price = sprintf('%.2f', $contract->ask_price);
            my $display_value = $contract->is_spread ? $contract->buy_level : $ask_price;

            $response = {
                longcode      => $contract->longcode,
                payout        => $contract->payout,
                ask_price     => $ask_price,
                display_value => $display_value,
                spot_time     => $contract->current_tick->epoch,
                date_start    => $contract->date_start->epoch,
            };

            # only required for non-spead contracts
            if ($p2->{from_pricer_daemon} and $p2->{amount_type}) {
                $response->{theo_probability}      = $contract->theo_probability->amount;
                $response->{base_commission}       = $contract->base_commission;
                $response->{probability_threshold} = $contract->market->deep_otm_threshold;
                $response->{minimum_stake}         = $contract->staking_limits->{min};
                $response->{maximum_payout}        = $contract->staking_limits->{max};
            }

            if ($contract->underlying->feed_license eq 'realtime') {
                $response->{spot} = $contract->current_spot;
            }
            $response->{spread} = $contract->spread if $contract->is_spread;
        }
        my $pen = $contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.buy.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => BOM::Platform::Context::localize("Cannot create contract"),
            code              => "ContractCreationFailure"
        });
    };

    return $response;
}

sub get_bid {
    my $params = shift;
    my ($short_code, $contract_id, $currency, $is_sold, $sell_time) = @{$params}{qw/short_code contract_id currency is_sold sell_time/};

    my $response;
    try {
        my $tv = [Time::HiRes::gettimeofday];
        my $contract = produce_contract($short_code, $currency, $is_sold);

        if ($contract->is_legacy) {
            $response = BOM::RPC::v3::Utility::create_error({
                message_to_client => $contract->longcode,
                code              => "GetProposalFailure"
            });
            return $response;
        }

        $response = {
            ask_price           => sprintf('%.2f', $contract->ask_price),
            bid_price           => sprintf('%.2f', $contract->bid_price),
            current_spot_time   => $contract->current_tick->epoch,
            contract_id         => $contract_id,
            underlying          => $contract->underlying->symbol,
            display_name        => $contract->underlying->display_name,
            is_expired          => $contract->is_expired,
            is_valid_to_sell    => $contract->is_valid_to_sell,
            is_forward_starting => $contract->is_forward_starting,
            is_path_dependent   => $contract->is_path_dependent,
            is_intraday         => $contract->is_intraday,
            date_start          => $contract->date_start->epoch,
            date_expiry         => $contract->date_expiry->epoch,
            date_settlement     => $contract->date_settlement->epoch,
            currency            => $contract->currency,
            longcode            => $contract->longcode,
            shortcode           => $contract->shortcode,
            payout              => $contract->payout,
            contract_type       => $contract->code
        };
        my @corporate_actions;

        if (not $contract->is_spread) {
            @corporate_actions = @{$contract->corporate_actions};

            my $contract_affected_by_missing_market_data = (not $contract->may_settle_automatically and $contract->missing_market_data) ? 1 : 0;
            if ($contract_affected_by_missing_market_data) {
                $response = BOM::RPC::v3::Utility::create_error({
                        code              => "GetProposalFailure",
                        message_to_client => localize(
                            'There was a market data disruption during the contract period. For real-money accounts we will attempt to correct this and settle the contract properly, otherwise the contract will be cancelled and refunded. Virtual-money contracts will be cancelled and refunded.'
                        )});
                return;
            }
        }

        if (not $contract->is_valid_to_sell and $contract->primary_validation_error) {
            $response->{validation_error} = $contract->primary_validation_error->message_to_client;
        }

        if (not $contract->is_spread) {
            $response->{entry_tick}      = $contract->underlying->pipsized_value($contract->entry_tick->quote) if $contract->entry_tick;
            $response->{entry_tick_time} = $contract->entry_tick->epoch                                        if $contract->entry_tick;
            $response->{exit_tick}       = $contract->underlying->pipsized_value($contract->exit_tick->quote)  if $contract->exit_tick;
            $response->{exit_tick_time}  = $contract->exit_tick->epoch                                         if $contract->exit_tick;
            $response->{current_spot} = $contract->current_spot if $contract->underlying->feed_license eq 'realtime';
            $response->{entry_spot} = $contract->underlying->pipsized_value($contract->entry_spot) if $contract->entry_spot;
            $response->{barrier_count} = $contract->two_barriers ? 2 : 1;

            # sell_spot and sell_spot_time are updated if the contract is sold
            # or when the contract is expired.
            if ($sell_time or $contract->is_expired) {
                my $sell_tick =
                    ($contract->is_path_dependent and $contract->hit_tick)
                    ? $contract->hit_tick
                    : $contract->underlying->tick_at($sell_time, {allow_inconsistent => 1});
                if ($sell_tick) {
                    $response->{sell_spot}      = $contract->underlying->pipsized_value($sell_tick->quote);
                    $response->{sell_spot_time} = $sell_tick->epoch;
                }
            }

            if ($contract->expiry_type eq 'tick') {
                $response->{tick_count} = $contract->tick_count;
            }

            if ($contract->entry_tick) {
                if ($contract->two_barriers) {
                    $response->{high_barrier}          = $contract->high_barrier->as_absolute;
                    $response->{low_barrier}           = $contract->low_barrier->as_absolute;
                    $response->{original_high_barrier} = $contract->original_high_barrier->as_absolute if defined $contract->original_high_barrier;
                    $response->{original_low_barrier}  = $contract->original_low_barrier->as_absolute if defined $contract->original_low_barrier;

                } elsif ($contract->barrier) {
                    $response->{barrier} = $contract->barrier->as_absolute;
                    $response->{original_barrier} = $contract->original_barrier->as_absolute if defined $contract->original_barrier;

                }
            }

            $response->{has_corporate_actions} = 1 if @corporate_actions;

        }

        my $pen = $contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.sell.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => BOM::Platform::Context::localize('Sorry, an error occurred while processing your request.'),
            code              => "GetProposalFailure"
        });
    };

    return $response;
}

sub send_ask {
    my $params             = shift;
    my $args               = $params->{args};
    my $from_pricer_daemon = shift;

    my $tv = [Time::HiRes::gettimeofday];

    my %details = %{$args};
    my $response;
    try {
        my $arguments = {
            from_pricer_daemon => $from_pricer_daemon,
            %details,
        };
        $response = _get_ask(prepare_ask($arguments));
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'pricing error',
                message_to_client => BOM::Platform::Locale::error_map()->{'pricing error'}});
    };

    $response->{rpc_time} = 1000 * Time::HiRes::tv_interval($tv);

    return $response;
}

sub get_contract_details {
    my $params = shift;

    my $client = $params->{client};

    my $response;
    try {
        my $contract = produce_contract($params->{short_code}, $params->{currency});
        $response = {
            longcode     => $contract->longcode,
            symbol       => $contract->underlying->symbol,
            display_name => $contract->underlying->display_name,
            date_expiry  => $contract->date_expiry->epoch
        };
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => localize('Sorry, an error occurred while processing your request.'),
            code              => "GetContractDetails"
        });
    };
    return $response;
}

sub validate_price {
    my $params = shift;

    return BOM::Product::Contract::Helper::validate_price($params);
}

sub calculate_ask_price {
    my $params = shift;

    my $commission_markup = BOM::Product::Contract::Helper::commission({
        theo_probability => $params->{theo_probability},
        base_commission  => $params->{base_commission},
        payout           => $params->{amount},
    });
    my $ask_probability = BOM::Product::Contract::Helper::calculate_ask_probability({
        theo_probability      => $params->{theo_probability},
        commission_markup     => $commission_markup,
        probability_threshold => $params->{probability_threshold},
    });

    return roundnear(0.01, $ask_probability * $params->{amount});
}

sub calculate_payout {
    my $params = shift;

    my $commission_markup = BOM::Product::Contract::Helper::commission({
        theo_probability => $params->{theo_probability},
        base_commission  => $params->{base_commission},
        stake            => $params->{amount},
    });
    my $payout = BOM::Product::Contract::Helper::calculate_payout({
        theo_probability => $params->{theo_probability},
        commission       => $commission_markup,
        stake            => $params->{amount},
    });

    return roundnear(0.01, $payout);
}

1;

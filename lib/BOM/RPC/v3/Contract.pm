package BOM::RPC::v3::Contract;

use strict;
use warnings;
no indirect;

use Try::Tiny;
use List::MoreUtils qw(none);
use Data::Dumper;
use Date::Utility;

use BOM::System::Config;
use BOM::RPC::v3::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Locale;
use BOM::Platform::Runtime;
use LandingCompany::Offerings qw(get_offerings_with_filter);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use Format::Util::Numbers qw(roundnear);
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);

use feature "state";

sub validate_symbol {
    my $symbol = shift;
    my @offerings = get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config, 'underlying_symbol');
    if (!$symbol || none { $symbol eq $_ } @offerings) {
        # There's going to be a few symbols that are disabled or otherwise not provided for valid reasons, but if we have nothing,
        # or it's a symbol that's very unlikely to be disabled, it'd be nice to know.
        warn "Symbol $symbol not found, our offerings are: " . join(',', @offerings)
            if $symbol and ($symbol =~ /^R_(100|75|50|25|10)$/ or not @offerings);
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
    my $u      = create_underlying($symbol);

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

sub validate_is_open {
    my $symbol = shift;
    my $u      = create_underlying($symbol);

    unless ($u->calendar->is_open) {
        return {
            error => {
                code    => 'MarketIsClosed',
                message => 'This market is presently closed.',
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

    $response = validate_is_open($symbol);
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
        $p2{duration} .= (delete $p2{duration_unit} or "s");
    }

    return \%p2;
}

sub _get_ask {
    my $p2                    = {%{+shift}};
    my $app_markup_percentage = shift;
    my $streaming_params      = delete $p2->{streaming_params};
    my ($contract, $response);

    my $tv = [Time::HiRes::gettimeofday];
    $p2->{app_markup_percentage} = $app_markup_percentage // 0;
    try {
        die unless pre_validate_start_expire_dates($p2);
    }
    catch {
        warn __PACKAGE__ . " _get_ask pre_validate_start_expire_dates failed, parameters: " . Dumper($p2);
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;
    try {
        $contract = produce_contract($p2);
    }
    catch {
        warn __PACKAGE__ . " _get_ask produce_contract failed, parameters: " . Dumper($p2);
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;

    try {
        if (!$contract->is_valid_to_buy) {
            my ($message_to_client, $code);

            if (my $pve = $contract->primary_validation_error) {

                $message_to_client = $pve->message_to_client;
                $code              = "ContractBuyValidationError";
            } else {
                $message_to_client = localize("Cannot validate contract");
                $code              = "ContractValidationError";
            }

            # When the date_expiry is smaller than date_start, we can not price, display the payout|stake on error message
            if ($contract->date_expiry->epoch <= $contract->date_start->epoch) {

                my $display_value = $contract->has_payout ? $contract->payout : $contract->ask_price;
                $response = BOM::RPC::v3::Utility::create_error({
                        continue_price_stream => $contract->continue_price_stream,
                        message_to_client     => $message_to_client,
                        code                  => $code,
                        details               => {
                            display_value => ($contract->is_spread ? $contract->buy_level : sprintf('%.2f', $display_value)),
                            payout => sprintf('%.2f', $display_value),
                        },
                    });

            } else {
                $response = BOM::RPC::v3::Utility::create_error({
                        continue_price_stream => $contract->continue_price_stream,
                        message_to_client     => $message_to_client,
                        code                  => $code,
                        details               => {
                            display_value => ($contract->is_spread ? $contract->buy_level : sprintf('%.2f', $contract->ask_price)),
                            payout => sprintf('%.2f', $contract->payout),
                        },
                    });
            }
        } else {
            my $ask_price = sprintf('%.2f', $contract->ask_price);
            my $trading_window_start = $p2->{trading_period_start} // '';
            # need this warning to be logged for Japan as a regulatory requirement
            warn $contract->japan_pricing_info($trading_window_start) if ($p2->{currency} && $p2->{currency} eq 'JPY');

            my $display_value = $contract->is_spread ? $contract->buy_level : $ask_price;
            my $market_name = $contract->market->name;
            my $base_commission_scaling =
                BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->per_market_scaling->$market_name;

            $response = {
                longcode            => $contract->longcode,
                payout              => $contract->payout,
                ask_price           => $ask_price,
                display_value       => $display_value,
                spot_time           => $contract->current_tick->epoch,
                date_start          => $contract->date_start->epoch,
                contract_parameters => {
                    %$p2,
                    !$contract->is_spread
                    ? (
                        app_markup_percentage => $contract->app_markup_percentage,
                        staking_limits        => $contract->staking_limits,
                        deep_otm_threshold    => $contract->otm_threshold,
                        )
                    : (),
                    underlying_base_commission => $contract->underlying->base_commission,
                    maximum_total_markup       => BOM::System::Config::quants->{commission}->{maximum_total_markup},
                    base_commission_min        => BOM::System::Config::quants->{commission}->{adjustment}->{minimum},
                    base_commission_max        => BOM::System::Config::quants->{commission}->{adjustment}->{maximum},
                    base_commission_scaling    => $base_commission_scaling,
                },
            };

            # only required for non-spead contracts
            if ($streaming_params->{add_theo_probability} and not $contract->is_spread) {
                $response->{theo_probability} = $contract->theo_probability->amount;
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
        _log_exception(_get_ask => $_);
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => BOM::Platform::Context::localize("Cannot create contract"),
            code              => "ContractCreationFailure"
        });
    };

    return $response;
}

sub get_bid {
    my $params = shift;
    my ($short_code, $contract_id, $currency, $is_sold, $sell_time, $buy_price, $sell_price, $app_markup_percentage, $landing_company) =
        @{$params}{qw/short_code contract_id currency is_sold sell_time buy_price sell_price app_markup_percentage landing_company/};

    my ($response, $contract, $bet_params);
    my $tv = [Time::HiRes::gettimeofday];
    try {
        $bet_params = shortcode_to_parameters($short_code, $currency);
    }
    catch {
        warn __PACKAGE__ . " get_bid shortcode_to_parameters failed: $short_code, currency: $currency";
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'GetProposalFailure',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;

    try {
        $bet_params->{is_sold}               = $is_sold;
        $bet_params->{app_markup_percentage} = $app_markup_percentage // 0;
        $bet_params->{landing_company}       = $landing_company;
        $contract                            = produce_contract($bet_params);
    }
    catch {
        warn __PACKAGE__ . " get_bid produce_contract failed, parameters: " . Dumper($bet_params);
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'GetProposalFailure',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;

    if ($contract->is_legacy) {
        return BOM::RPC::v3::Utility::create_error({
            message_to_client => $contract->longcode,
            code              => "GetProposalFailure"
        });
    }

    try {
        my $is_valid_to_sell = $contract->is_spread ? $contract->is_valid_to_sell : $contract->is_valid_to_sell($params->{validation_params});

        $response = {
            is_valid_to_sell => $is_valid_to_sell,
            ($is_valid_to_sell ? () : (validation_error => $contract->primary_validation_error->message_to_client)),
            bid_price           => sprintf('%.2f', $contract->bid_price),
            current_spot_time   => $contract->current_tick->epoch,
            contract_id         => $contract_id,
            underlying          => $contract->underlying->symbol,
            display_name        => $contract->underlying->display_name,
            is_expired          => $contract->is_expired,
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

        if ($contract->is_spread) {
            # spreads require different set of parameters.
            my $sign = $contract->sentiment eq 'up' ? '+' : '-';
            my $amount_per_point = $sign . $contract->amount_per_point;
            $response->{amount_per_point}  = $amount_per_point;
            $response->{entry_level}       = $contract->barrier->as_absolute;
            $response->{stop_loss_level}   = $contract->stop_loss_level;
            $response->{stop_profit_level} = $contract->stop_profit_level;

            if ($contract->is_sold and defined $sell_price and defined $buy_price) {
                $response->{is_expired} = 1;
                my $pnl              = $sell_price - $buy_price;
                my $point_from_entry = $pnl / $contract->amount_per_point;
                my $multiplier       = $contract->sentiment eq 'up' ? 1 : -1;
                $response->{exit_level} = $contract->underlying->pipsized_value($response->{entry_level} + $point_from_entry * $multiplier);
                $response->{current_value_in_dollar} = $pnl;
                $response->{current_value_in_point}  = $point_from_entry;
            } else {
                if ($contract->is_expired) {
                    $response->{is_expired}              = 1;
                    $response->{exit_level}              = $contract->exit_level;
                    $response->{current_value_in_dollar} = $contract->value;
                    $response->{current_value_in_point}  = $contract->point_value;
                } else {
                    $response->{is_expired}              = 0;
                    $response->{current_level}           = $contract->sell_level;
                    $response->{current_value_in_dollar} = $contract->current_value->{dollar};
                    $response->{current_value_in_point}  = $contract->current_value->{point};
                }
            }
        } else {
            if (not $contract->may_settle_automatically and $contract->missing_market_data) {
                $response = BOM::RPC::v3::Utility::create_error({
                        code              => "GetProposalFailure",
                        message_to_client => localize(
                            'There was a market data disruption during the contract period. For real-money accounts we will attempt to correct this and settle the contract properly, otherwise the contract will be cancelled and refunded. Virtual-money contracts will be cancelled and refunded.'
                        )});
                return;
            }

            $response->{is_settleable} = $contract->is_settleable;
            $response->{has_corporate_actions} = 1 if @{$contract->corporate_actions};

            $response->{barrier_count} = $contract->two_barriers ? 2 : 1;
            if ($contract->entry_tick) {
                my $entry_spot = $contract->underlying->pipsized_value($contract->entry_tick->quote);
                $response->{entry_tick}      = $entry_spot;
                $response->{entry_spot}      = $entry_spot;
                $response->{entry_tick_time} = $contract->entry_tick->epoch;
                if ($contract->two_barriers) {
                    $response->{high_barrier}          = $contract->high_barrier->as_absolute;
                    $response->{low_barrier}           = $contract->low_barrier->as_absolute;
                    $response->{original_high_barrier} = $contract->original_high_barrier->as_absolute
                        if defined $contract->original_high_barrier;
                    $response->{original_low_barrier} = $contract->original_low_barrier->as_absolute if defined $contract->original_low_barrier;
                } elsif ($contract->barrier) {
                    $response->{barrier} = $contract->barrier->as_absolute;
                    $response->{original_barrier} = $contract->original_barrier->as_absolute if defined $contract->original_barrier;
                }
            }

            if ($contract->exit_tick and $contract->is_after_settlement) {
                $response->{exit_tick}      = $contract->underlying->pipsized_value($contract->exit_tick->quote);
                $response->{exit_tick_time} = $contract->exit_tick->epoch;
            }

            $response->{current_spot} = $contract->current_spot if $contract->underlying->feed_license eq 'realtime';

            # sell_spot and sell_spot_time are updated if the contract is sold
            # or when the contract is expired.
            if ($sell_time or $contract->is_expired) {
                $response->{is_expired} = 1;

                # path dependent contracts may have hit tick but not sell time
                my $sell_tick = $sell_time ? $contract->underlying->tick_at($sell_time, {allow_inconsistent => 1}) : undef;

                my $hit_tick;
                if ($contract->is_path_dependent and $hit_tick = $contract->hit_tick and (not $sell_time or $hit_tick->epoch <= $sell_time)) {
                    $sell_tick = $hit_tick;
                }

                if ($sell_tick) {
                    $response->{sell_spot}      = $contract->underlying->pipsized_value($sell_tick->quote);
                    $response->{sell_spot_time} = $sell_tick->epoch;
                }
            }

            if ($contract->expiry_type eq 'tick') {
                $response->{tick_count} = $contract->tick_count;
            }
        }
        my $pen = $contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.sell.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
    }
    catch {
        _log_exception(get_bid => $_);
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => BOM::Platform::Context::localize('Sorry, an error occurred while processing your request.'),
            code              => "GetProposalFailure"
        });
    };

    return $response;
}

sub send_bid {
    my $params = shift;

    my $tv = [Time::HiRes::gettimeofday];

    my $response;
    try {
        $response = get_bid($params);
    }
    catch {
        # This should be impossible: get_bid() has an exception wrapper around
        # all the useful code, so unless the error creation or localize steps
        # fail, there's not much else that can go wrong. We therefore log and
        # report anyway.
        _log_exception(send_bid => "$_ (and it should be impossible for this to happen)");
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'pricing error',
                message_to_client => BOM::RPC::v3::Utility::error_map()->{'pricing error'}});
    };

    $response->{rpc_time} = 1000 * Time::HiRes::tv_interval($tv);

    return $response;
}

sub send_ask {
    my $params = shift;

    my $tv = [Time::HiRes::gettimeofday];

    # provide landing_company information when it is available.
    $params->{args}->{landing_company} = $params->{landing_company} if $params->{landing_company};

    my $symbol   = $params->{args}->{symbol};
    my $response = validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        $response = BOM::RPC::v3::Utility::create_error({
                code              => $response->{error}->{code},
                message_to_client => BOM::Platform::Context::localize($response->{error}->{message}, $symbol)});

        $response->{rpc_time} = 1000 * Time::HiRes::tv_interval($tv);

        return $response;
    }

    try {

        $response = _get_ask(prepare_ask($params->{args}), $params->{app_markup_percentage});

    }
    catch {
        _log_exception(send_ask => $_);
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'pricing error',
                message_to_client => BOM::RPC::v3::Utility::error_map()->{'pricing error'}});
    };

    $response->{rpc_time} = 1000 * Time::HiRes::tv_interval($tv);
    map { exists($response->{$_}) && ($response->{$_} .= '') } qw(ask_price barrier date_start display_value payout spot spot_time);
    return $response;
}

sub send_multiple_ask {
    my $params         = {%{+shift}};
    my $barriers_array = delete $params->{args}->{barriers};
    my $responses      = [];
    my $rpc_time       = 0;

    for my $barriers (@$barriers_array) {
        $params->{args}->{barrier} = $barriers->{barrier};
        @{$params->{args}}{keys %$barriers} = values %$barriers;
        my $res = send_ask($params);
        if (not exists $res->{error}) {
            @{$res}{keys %$barriers} = values %$barriers;
            push @$responses, $res;
        } else {
            $res->{error}{continue_price_stream} = 1;    # we continue price stream because for multiple_ask
            @{$res->{error}{details}}{keys %$barriers} = values %$barriers;
            push @$responses, $res;
        }
        $rpc_time += $res->{rpc_time} // 0;
        delete $res->{rpc_time};
    }

    return {
        proposals => $responses,
        rpc_time  => $rpc_time,
    };
}

sub get_contract_details {
    my $params = shift;

    my $client = $params->{client};

    my ($response, $contract, $bet_params);
    try {
        $bet_params = shortcode_to_parameters($params->{short_code}, $params->{currency});
    }
    catch {
        warn __PACKAGE__ . " get_contract_details shortcode_to_parameters failed: $params->{short_code}, currency: $params->{currency}";
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'GetContractDetails',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;

    try {
        $bet_params->{app_markup_percentage} = $params->{app_markup_percentage} // 0;
        $bet_params->{landing_company}       = $client->landing_company->short;
        $contract                            = produce_contract($bet_params);
    }
    catch {
        warn __PACKAGE__ . " get_contract_details produce_contract failed, parameters: " . Dumper($bet_params);
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'GetContractDetails',
                message_to_client => BOM::Platform::Context::localize('Cannot create contract')});
    };
    return $response if $response;

    $response = {
        longcode     => $contract->longcode,
        symbol       => $contract->underlying->symbol,
        display_name => $contract->underlying->display_name,
        date_expiry  => $contract->date_expiry->epoch
    };
    return $response;
}

sub _log_exception {
    my ($component, $err) = @_;
    # so this should never happen, because we're passing fixed strings and only in this module,
    # but best not to let a typo ruin datadog's day
    $component =~ s/[^a-z_]+/_/g and warn "invalid component passed to _log_error: $_[0]";
    warn "Unhandled exception in $component: $err\n";
    stats_inc('contract.exception.' . $component);
    return;
}

# pre-check
# this sub indicates error on RPC level if date_start or date_expiry of a new ask/contract are too far from now
sub pre_validate_start_expire_dates {
    my $params = shift;
    my ($start_epoch, $expiry_epoch, $duration);

    state $pre_limits_max_duration = 31536000;    # 365 days
    state $pre_limits_max_forward  = 604800;      # 7 days (Maximum offset from now for creating a contract)

    my $now_epoch = Date::Utility->new->epoch;
    # no try/catch here, expecting higher level try/catch
    $start_epoch = $params->{date_start} ? Date::Utility->new($params->{date_start})->epoch : $now_epoch;
    if ($params->{duration}) {
        if ($params->{duration} =~ /^(\d+)t$/) {    # ticks
            $duration = $1 * 2;
        } else {
            $duration = Time::Duration::Concise->new(interval => $params->{duration})->seconds;
        }
        $expiry_epoch = $start_epoch + $duration;
    } else {
        $expiry_epoch = Date::Utility->new($params->{date_expiry})->epoch;
        $duration     = $expiry_epoch - $start_epoch;
    }

    return if $start_epoch + 5 < $now_epoch or $start_epoch - $now_epoch > $pre_limits_max_forward or $duration > $pre_limits_max_duration;

    return 1;    # seems like ok, but everything will be fully checked later.
}

1;

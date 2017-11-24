package BOM::Pricing::v3::Contract;

use strict;
use warnings;
no indirect;

use Scalar::Util qw(blessed);
use Try::Tiny;
use List::MoreUtils qw(none);
use JSON::XS;
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use Time::HiRes;
use Time::Duration::Concise::Localize;

use Format::Util::Numbers qw/formatnumber/;
use LandingCompany::Offerings qw(get_offerings_with_filter);

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Config;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Locale;
use BOM::Platform::Runtime;
use BOM::Product::ContractFactory qw(produce_contract produce_batch_contract);
use Finance::Contract::Longcode qw( shortcode_to_parameters);
use BOM::Product::Contract::Finder::Japan;
use BOM::Product::Contract::Finder;
use BOM::Product::Contract::Offerings;
use BOM::Pricing::v3::Utility;
use BOM::Pricing::ContractsForGenerator;

use feature "state";

sub _create_error {
    my $args = shift;
    stats_inc("bom_pricing_rpc.v_3.error", {tags => ['code:' . $args->{code},]});
    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{message} ? (message => $args->{message}) : (),
        }};
}

sub _validate_symbol {
    my $symbol = shift;
    my @offerings = get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config, 'underlying_symbol');
    if (!$symbol || none { $symbol eq $_ } @offerings) {

# There's going to be a few symbols that are disabled or otherwise not provided for valid reasons, but if we have nothing,
# or it's a symbol that's very unlikely to be disabled, it'd be nice to know.
        warn "Symbol $symbol not found, our offerings are: " . join(',', @offerings)
            if $symbol
            and ($symbol =~ /^R_(100|75|50|25|10)$/ or not @offerings);
        return {
            error => {
                code    => 'InvalidSymbol',
                message => "Symbol [_1] invalid",
                params  => [$symbol],
            }};
    }
    return;
}

sub prepare_ask {
    my $p1 = shift;
    my %p2 = %$p1;

    my @contract_types = ref($p2{contract_type}) ? @{$p2{contract_type}} : ($p2{contract_type});
    delete $p2{contract_type};
    $p2{date_start} //= 0;
    if ($p2{date_expiry}) {
        $p2{fixed_expiry} //= 1;
    }

    if (ref $p2{barriers}) {
        delete @p2{qw(barrier barrier2)};
    } elsif (defined $p2{barrier} && defined $p2{barrier2}) {
        $p2{low_barrier}  = delete $p2{barrier2};
        $p2{high_barrier} = delete $p2{barrier};
    } elsif (
        !grep {
            /^(ASIAN|DIGITEVEN|DIGITODD)/
        } @contract_types
        )
    {
        $p2{barrier} //= 'S0P';
        delete $p2{barrier2};
    }

    $p2{underlying} = delete $p2{symbol};
    if (@contract_types > 1) {
        $p2{bet_types} = \@contract_types;
    } else {
        ($p2{bet_type}) = @contract_types;
    }
    $p2{amount_type} = delete $p2{basis} if exists $p2{basis};
    if ($p2{duration} and not exists $p2{date_expiry}) {
        $p2{duration} .= (delete $p2{duration_unit} or "s");
    }

    return \%p2;
}

=head2 contract_metadata

Extracts some generic information from a given contract.

=cut

sub contract_metadata {
    my ($contract) = @_;
    return +{
        app_markup_percentage => $contract->app_markup_percentage,
        staking_limits        => $contract->staking_limits,
        deep_otm_threshold    => $contract->otm_threshold,
        base_commission       => $contract->base_commission,
    };
}

sub _get_ask {
    my ($args_copy, $app_markup_percentage) = @_;
    my $streaming_params = delete $args_copy->{streaming_params};
    my ($contract, $response, $contract_parameters);

    my $tv = [Time::HiRes::gettimeofday];
    $args_copy->{app_markup_percentage} = $app_markup_percentage // 0;

    try {
        $contract = $args_copy->{proposal_array} ? produce_batch_contract($args_copy) : produce_contract($args_copy);
    }
    catch {
        my $message_to_client = _get_error_message($_, $args_copy);
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => localize(@$message_to_client)});
    };
    return $response if $response;

    if ($contract->isa('BOM::Product::Contract::Batch')) {
        my $batch_response = try {
            handle_batch_contract($contract, $args_copy);
        }
        catch {
            my $message_to_client = _get_error_message($_, $args_copy);
            BOM::Pricing::v3::Utility::create_error({
                    code              => 'ContractCreationFailure',
                    message_to_client => localize(@$message_to_client)});
        };

        return $batch_response;
    }

    try {
        $contract_parameters = {%$args_copy, %{contract_metadata($contract)}};
    }
    catch {
        my $message_to_client = _get_error_message($_, $args_copy);
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'ContractCreationFailure',
                message_to_client => localize(@$message_to_client)});
    };
    return $response if $response;

    try {
        if (!($contract->is_valid_to_buy({landing_company => $args_copy->{landing_company}}))) {
            my ($message_to_client, $code);

            if (my $pve = $contract->primary_validation_error) {
                $message_to_client = localize($pve->message_to_client);
                $code              = "ContractBuyValidationError";
            } else {
                $message_to_client = localize("Cannot validate contract.");
                $code              = "ContractValidationError";
            }

            $response = _create_error({
                message_to_client => $message_to_client,
                code              => $code,
            });

            # proposal_array streaming could get error on a first call
            # but later could produce valid contract dependant on volatility moves
            # so we need to store contract_parameters and longcode to use them later
            if ($code eq 'ContractBuyValidationError') {
                my $longcode =
                    eval { $contract->longcode } || '';    # if we can't get the longcode that's fine, we still want to return the original error
                $response->{contract_parameters} = $contract_parameters;
                $response->{longcode} = $longcode ? localize($longcode) : '';
            }
        } else {
            # We think this contract is valid to buy
            my $ask_price = formatnumber('price', $contract->currency, $contract->ask_price);

            $response = {
                longcode            => localize($contract->longcode),
                payout              => $contract->payout,
                ask_price           => $ask_price,
                display_value       => $ask_price,
                spot_time           => $contract->current_tick->epoch,
                date_start          => $contract->date_start->epoch,
                contract_parameters => $contract_parameters,
            };

            if ($streaming_params->{add_theo_probability}) {
                $response->{theo_probability} = $contract->theo_probability->amount;
            }

            if ($contract->underlying->feed_license eq 'realtime') {
                $response->{spot} = $contract->current_spot;
            }
        }
        my $pen = $contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.buy.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
    }
    catch {
        my $message_to_client = _get_error_message($_, $args_copy, 1);
        $response = BOM::Pricing::v3::Utility::create_error({
            message_to_client => localize(@$message_to_client),
            code              => "ContractCreationFailure"
        });
    };

    return $response;
}

sub handle_batch_contract {
    my ($batch_contract, $p2) = @_;

    # We should now have a usable ::Contract instance. This may be a single
    # or multiple (batch) contract.

    my $proposals            = {};
    my $ask_prices           = $batch_contract->ask_prices;
    my $trading_window_start = $p2->{trading_period_start} // '';

    # Log full pricing data for Japan contracts. This is a regulatory requirement
    # with strict rules about accuracy.
    if ($p2->{currency} && $p2->{currency} eq 'JPY') {
        my %contracts_to_log;
        CONTRACT:
        for my $contract (@{$batch_contract->_contracts}) {
            next CONTRACT unless $contract->can('japan_pricing_info');

            my $barrier_key =
                $contract->two_barriers
                ? ($contract->high_barrier->as_absolute) . '-' . ($contract->low_barrier->as_absolute)
                : ($contract->barrier->as_absolute);

            push @{$contracts_to_log{$barrier_key}}, $contract;
        }
        BARRIER:
        for my $contracts (values %contracts_to_log) {
            if (@$contracts == 2) {
                # For each contract, we pass the opposite contract to the logging function
                warn $contracts->[0]->japan_pricing_info($trading_window_start, $contracts->[1]);
                warn $contracts->[1]->japan_pricing_info($trading_window_start, $contracts->[0]);
            } else {
                warn "Had unexpected number of contracts for ->japan_pricing_info calls - types are " . join ',', map { $_->bet_type } @$contracts;
            }
        }
    }
    for my $contract_type (keys %$ask_prices) {
        for my $barrier (@{$p2->{barriers}}) {
            my $key =
                ref($barrier)
                ? $batch_contract->underlying->pipsized_value($barrier->{barrier}) . '-'
                . $batch_contract->underlying->pipsized_value($barrier->{barrier2})
                : $batch_contract->underlying->pipsized_value($barrier);
            warn "Could not find barrier for key $key, available barriers: " . join ',', sort keys %{$ask_prices->{$contract_type}}
                unless exists $ask_prices->{$contract_type}{$key};
            my $price = $ask_prices->{$contract_type}{$key} // {};
            push @{$proposals->{$contract_type}}, $price;
        }
    }
    return {
        proposals           => $proposals,
        contract_parameters => {%$p2, %{$batch_contract->market_details}},
        rpc_time            => 0,                                            # $rpc_time,
    };
}

sub get_bid {
    my $params = shift;
    my ($short_code, $contract_id, $currency, $is_sold, $is_expired, $sell_time, $sell_price, $app_markup_percentage, $landing_company) =
        @{$params}{qw/short_code contract_id currency is_sold is_expired sell_time sell_price app_markup_percentage landing_company/};

    my ($response, $contract, $bet_params);
    my $tv = [Time::HiRes::gettimeofday];
    try {
        $bet_params = shortcode_to_parameters($short_code, $currency);
    }
    catch {
        warn __PACKAGE__ . " get_bid shortcode_to_parameters failed: $short_code, currency: $currency";
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'GetProposalFailure',
                message_to_client => localize('Cannot create contract')});
    };
    return $response if $response;

    try {
        $bet_params->{is_sold}               = $is_sold;
        $bet_params->{app_markup_percentage} = $app_markup_percentage // 0;
        $bet_params->{landing_company}       = $landing_company;
        $contract                            = produce_contract($bet_params);
    }
    catch {
        warn __PACKAGE__ . " get_bid produce_contract failed, parameters: " . JSON::XS->new->allow_blessed->encode($bet_params);
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'GetProposalFailure',
                message_to_client => localize('Cannot create contract')});
    };
    return $response if $response;

    # rare case: no tics between date_start and date_expiry.
    # underlaying will return exit_tick preceding date_start
    return _data_disruption_error() if $contract->exit_tick and $contract->date_start->epoch > $contract->exit_tick->epoch;

    if ($contract->is_legacy) {
        return BOM::Pricing::v3::Utility::create_error({
            message_to_client => localize($contract->longcode),
            code              => "GetProposalFailure"
        });
    }

    try {
        $params->{validation_params}->{landing_company} = $landing_company;
        my $is_valid_to_sell = $contract->is_valid_to_sell($params->{validation_params});
        $response = {
            is_valid_to_sell    => $is_valid_to_sell,
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
            longcode            => localize($contract->longcode),
            shortcode           => $short_code,
            payout              => $contract->payout,
            contract_type       => $contract->code,
            bid_price           => formatnumber('price', $contract->currency, $contract->bid_price),
        };

        if ($is_sold and $is_expired) {
            # here sell_price is used to parse the status of contracts that settled from bo
            $response->{status} = $sell_price == $contract->payout ? "won" : "lost";
        } elsif ($is_sold and not $is_expired) {
            $response->{status} = 'sold';
        } else {    # not sold
            $response->{status} = 'open';
        }

        $response->{validation_error} = localize($contract->primary_validation_error->message_to_client) unless $is_valid_to_sell;

        if (not $contract->may_settle_automatically
            and $contract->missing_market_data)
        {
            $response = _data_disruption_error();
            return;
        }

        $response->{is_settleable} = $contract->is_settleable;

        $response->{barrier_count} = $contract->two_barriers ? 2 : 1;
        if ($contract->entry_spot) {
            my $entry_spot = $contract->underlying->pipsized_value($contract->entry_spot);
            $response->{entry_tick}      = $entry_spot;
            $response->{entry_spot}      = $entry_spot;
            $response->{entry_tick_time} = $contract->entry_spot_epoch;
            if ($contract->two_barriers) {
                $response->{high_barrier} = $contract->high_barrier->as_absolute;
                $response->{low_barrier}  = $contract->low_barrier->as_absolute;
            } elsif ($contract->barrier) {
                $response->{barrier} = $contract->barrier->as_absolute;
            }
        }

        if ($contract->exit_tick and $contract->is_valid_exit_tick and $contract->is_after_settlement) {
            $response->{exit_tick}      = $contract->underlying->pipsized_value($contract->exit_tick->quote);
            $response->{exit_tick_time} = $contract->exit_tick->epoch;
        }

        if ($contract->is_settleable || $contract->is_sold) {
            my $localized_audit_details;
            my $ad = $contract->audit_details;
            foreach my $key (keys %$ad) {
                $localized_audit_details->{$key} = [
                    map {
                        if ($_->{name}) { $_->{name} = localize($_->{name}) }
                        $_
                    } @{$ad->{$key}}];
            }
            $response->{audit_details} = $localized_audit_details;
        }

        $response->{current_spot} = $contract->current_spot
            if $contract->underlying->feed_license eq 'realtime';

        # sell_spot and sell_spot_time are updated if the contract is sold
        # or when the contract is expired.
        if ($sell_time or $contract->is_expired) {
            # path dependent contracts may have hit tick but not sell time
            my $sell_tick =
                  $sell_time
                ? $contract->underlying->tick_at($sell_time, {allow_inconsistent => 1})
                : undef;

            my $hit_tick;
            if (    $contract->is_path_dependent
                and $hit_tick = $contract->hit_tick
                and (not $sell_time or $hit_tick->epoch <= $sell_time))
            {
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

        my $pen = $contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.sell.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
    }
    catch {
        _log_exception(get_bid => $_);
        $response = BOM::Pricing::v3::Utility::create_error({
            message_to_client => localize('Sorry, an error occurred while processing your request.'),
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
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'pricing error',
                message_to_client => localize('Unable to price the contract.')});
    };

    $response->{rpc_time} = 1000 * Time::HiRes::tv_interval($tv);

    return $response;
}

sub send_ask {
    my $params = shift;

    my $tv = [Time::HiRes::gettimeofday];

    # provide landing_company information when it is available.
    $params->{args}->{landing_company} = $params->{landing_company}
        if $params->{landing_company};

    my $symbol   = $params->{args}->{symbol};
    my $response = _validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => $response->{error}->{code},
                message_to_client => localize($response->{error}->{message}, $symbol)});

        $response->{rpc_time} = 1000 * Time::HiRes::tv_interval($tv);

        return $response;
    }

    try {
        $response = _get_ask(prepare_ask($params->{args}), $params->{app_markup_percentage});
    }
    catch {
        _log_exception(send_ask => $_);
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'pricing error',
                message_to_client => localize('Unable to price the contract.')});
    };

    $response->{rpc_time} = 1000 * Time::HiRes::tv_interval($tv);

    # Stringify all returned numeric values
    $response->{$_} .= '' for grep { exists $response->{$_} } qw(ask_price barrier date_start display_value payout spot spot_time);
    return $response;
}

sub get_contract_details {
    my $params = shift;

    die 'missing landing_company in params'
        if !exists $params->{landing_company};

    my ($response, $contract, $bet_params);
    try {
        $bet_params =
            shortcode_to_parameters($params->{short_code}, $params->{currency});
    }
    catch {
        warn __PACKAGE__ . " get_contract_details shortcode_to_parameters failed: $params->{short_code}, currency: $params->{currency}";
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'GetContractDetails',
                message_to_client => localize('Cannot create contract')});
    };
    return $response if $response;

    try {
        $bet_params->{app_markup_percentage} = $params->{app_markup_percentage} // 0;
        $bet_params->{landing_company}       = $params->{landing_company};
        $contract                            = produce_contract($bet_params);
    }
    catch {
        warn __PACKAGE__ . " get_contract_details produce_contract failed, parameters: " . JSON::XS->new->allow_blessed->encode($bet_params);
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'GetContractDetails',
                message_to_client => localize('Cannot create contract')});
    };
    return $response if $response;

    $response = {
        longcode     => localize($contract->longcode),
        symbol       => $contract->underlying->symbol,
        display_name => $contract->underlying->display_name,
        date_expiry  => $contract->date_expiry->epoch
    };

    # do not have any other information on legacy contract
    return $response if ($contract->is_legacy or $contract->is_binaryico);

    if ($contract->two_barriers) {
        $response->{high_barrier} = $contract->high_barrier->supplied_barrier;
        $response->{low_barrier}  = $contract->low_barrier->supplied_barrier;
    } else {
        $response->{barrier} = $contract->barrier ? $contract->barrier->supplied_barrier : undef;
    }

    return $response;
}

sub contracts_for {
    my $params = shift;

    my $args                 = $params->{args};
    my $symbol               = $args->{contracts_for};
    my $currency             = $args->{currency} || 'USD';
    my $product_type         = $args->{product_type} // 'basic';
    my $landing_company_name = $args->{landing_company} // 'costarica';

    my $contracts_for =
        BOM::Platform::RedisReplicated::redis_pricer()->get(join(':', 'contracts_for', $landing_company_name, $product_type, $symbol));
    if ($contracts_for) {
        $contracts_for = JSON::XS->new->decode($contracts_for);
        $contracts_for = undef if $contracts_for->{_generated} < time - 30;
    }

    if ($contracts_for) {
        stats_inc('bom_pricing.precalculated_data.used', {tags => ['data:' . 'contracts_for',]});
    } else {
        stats_inc('bom_pricing.precalculated_data.missed', {tags => ['data:' . 'contracts_for',]});
        $contracts_for = BOM::Pricing::ContractsForGenerator::contracts_for({
            product_type    => $product_type,
            landing_company => $landing_company_name,
            symbol          => $symbol,
        });
    }
    $contracts_for = $contracts_for->{value};

    foreach my $contract (@{$contracts_for->{available}}) {
        if (exists $contract->{payout_limit}) {
            $contract->{payout_limit} = $contract->{payout_limit}->{$currency};
        }
    }

    if (not $contracts_for or $contracts_for->{hit_count} == 0) {
        return BOM::Pricing::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize('The symbol is invalid.')});
    }
    return $contracts_for;
}

sub _log_exception {
    my ($component, $err) = @_;

# so this should never happen, because we're passing fixed strings and only in this module,
# but best not to let a typo ruin datadog's day
    $component =~ s/[^a-z_]+/_/g
        and warn "invalid component passed to _log_error: $_[0]";
    warn "Unhandled exception in $component: $err\n";
    stats_inc('contract.exception.' . $component);
    return;
}

sub _get_error_message {
    my ($reason, $args_copy, $log_exception) = @_;

    return $reason->message_to_client if (blessed($reason) && $reason->isa('BOM::Product::Exception'));

    if ($log_exception) {
        _log_exception(_get_ask => $reason);
    } else {
        warn __PACKAGE__ . " _get_ask produce_contract failed: $reason, parameters: " . JSON::XS->new->allow_blessed->encode($args_copy);
    }

    return ['Cannot create contract'];
}

sub _data_disruption_error {
    return BOM::Pricing::v3::Utility::create_error({
            code              => "GetProposalFailure",
            message_to_client => localize(
                'There was a market data disruption during the contract period. For real-money accounts we will attempt to correct this and settle the contract properly, otherwise the contract will be cancelled and refunded. Virtual-money contracts will be cancelled and refunded.'
            )});
}

1;

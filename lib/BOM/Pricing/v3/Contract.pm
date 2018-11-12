package BOM::Pricing::v3::Contract;

use strict;
use warnings;
no indirect;

use Scalar::Util qw(blessed);
use Try::Tiny;
use List::MoreUtils qw(none);
use JSON::MaybeXS;
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use Time::HiRes;
use Time::Duration::Concise::Localize;
use BOM::User::Client;

use Format::Util::Numbers qw/formatnumber/;
use Scalar::Util::Numeric qw(isint);

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Config;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Locale;
use BOM::Config::Runtime;
use BOM::Product::ContractFactory qw(produce_contract produce_batch_contract);
use BOM::Product::ContractFinder;
use Finance::Contract::Longcode qw( shortcode_to_parameters);
use BOM::Product::ContractFinder;
use LandingCompany::Registry;
use BOM::Pricing::v3::Utility;
use Scalar::Util qw(looks_like_number);
use feature "state";

my $json = JSON::MaybeXS->new->allow_blessed;

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
            /^(ASIAN|DIGITEVEN|DIGITODD|DIGITMATCH|DIGITDIFF|TICKHIGH|TICKLOW|LBFLOATCALL|LBFLOATPUT|LBHIGHLOW)/
        } @contract_types
        )
    {
        $p2{barrier} //= 'S0P';
        delete $p2{barrier2};

        if (    grep { /^(CALL|PUT)E?$/ } @contract_types
            and looks_like_number($p2{barrier})
            and $p2{barrier} == 0)
        {
            $p2{barrier} = 'S0P';
        }

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
        ($contract->is_binary) ? (staking_limits => $contract->staking_limits) : (),    #staking limits only apply to binary
        deep_otm_threshold => $contract->otm_threshold,
        base_commission    => $contract->base_commission,
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

    $response = _validate_offerings($contract, $args_copy);

    return $response if $response;

    try {
        $contract_parameters = {%$args_copy, %{contract_metadata($contract)}};
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

            if ($streaming_params->{add_theo_probability} and $contract->is_binary) {
                $response->{theo_probability} = $contract->theo_probability->amount;
            }

            unless ($contract->is_binary) {
                $response->{contract_parameters}->{skip_stream_results_adjustment} = 1;
            }

            if ($contract->underlying->feed_license eq 'realtime') {
                $response->{spot} = $contract->current_spot;
            }

            $response->{multiplier} = $contract->multiplier unless $contract->is_binary;

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

    my $proposals = {};

    # This is done with an assumption that batch contracts has identical duration and contract category
    my $offerings_error = _validate_offerings($batch_contract->_contracts->[0], $p2);

    my $ask_prices = $batch_contract->ask_prices;

    for my $contract_type (sort keys %$ask_prices) {
        for my $barrier (@{$p2->{barriers}}) {
            my $key =
                ref($barrier)
                ? $batch_contract->underlying->pipsized_value($barrier->{barrier}) . '-'
                . $batch_contract->underlying->pipsized_value($barrier->{barrier2})
                : $batch_contract->underlying->pipsized_value($barrier);
            warn "Could not find barrier for key $key, available barriers: " . join ',', sort keys %{$ask_prices->{$contract_type}}
                unless exists $ask_prices->{$contract_type}{$key};
            my $price = $ask_prices->{$contract_type}{$key} // {};
            if ($offerings_error) {
                my $new_error = {
                    longcode => $price->{longcode},
                    error    => {
                        message_to_client => $offerings_error->{error}{message_to_client},
                        code              => $offerings_error->{error}{code},
                        details           => {
                            display_value => $price->{error} ? $price->{error}{details}{display_value} : $price->{display_value},
                            payout        => $price->{error} ? $price->{error}{details}{payout}        : $price->{display_value},
                        }
                    },
                };
                if (ref($barrier)) {
                    $new_error->{error}{details}{barrier}  = $batch_contract->underlying->pipsized_value($barrier->{barrier});
                    $new_error->{error}{details}{barrier2} = $batch_contract->underlying->pipsized_value($barrier->{barrie2});
                } else {
                    $new_error->{error}{details}{barrier} = $batch_contract->underlying->pipsized_value($barrier);
                }
                $price = $new_error;
            }
            push @{$proposals->{$contract_type}}, $price;
        }
    }
    return {
        proposals           => $proposals,
        contract_parameters => {%$p2, %{$batch_contract->market_details}},
        rpc_time            => 0,                                            # $rpc_time,
    };
}

=head2 get_bid

Description Builds the L<open contract response|https://developers.binary.com/api/#proposal_open_contract> api response from the stored contract.

    get_bid(\%params);

Takes the following arguments as parameters

=over 4

=item short_code  String Coded description of the contract purchased, Example: CALL_R_100_90_1446704187_1446704787_S0P_0

=item contract_id  Integer internal identifier of the purchased Contract

=item currency  String  Standard 3 letter currency code of the contract.

=item is_sold  Boolean  Whether the contract is sold or not.

=item is_expired  Boolean  Whether the contract is expired or not.

=item sell_time   Integer Epoch time of when the contract was sold (only present for contracts already sold)

=item sell_price   Numeric Price at which contract was sold, only available when contract has been sold.

=item app_markup_percentage 3rd party application markup percentage. 

=item landing_company  String The landing company shortcode of the client.

=item country_code  String International 2 letter country code of the client.

=back

Returns a contract proposal response as a  Hashref or an error from  L<BOM::Pricing::V3::Utility>

=cut

sub get_bid {
    my $params = shift;

    my (
        $short_code, $contract_id, $currency,              $is_sold,         $is_expired,
        $sell_time,  $sell_price,  $app_markup_percentage, $landing_company, $country_code
        )
        = @{$params}{qw/short_code contract_id currency is_sold is_expired sell_time sell_price app_markup_percentage landing_company country_code/};

    my ($response, $contract, $bet_params);
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
        $bet_params->{sell_time}             = $sell_time if $is_sold;
        $contract                            = produce_contract($bet_params);
    }
    catch {
        warn __PACKAGE__ . " get_bid produce_contract failed, parameters: " . $json->encode($bet_params);
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'GetProposalFailure',
                message_to_client => localize('Cannot create contract')});
    };
    return $response if $response;

    # rare case: no tics between date_start and date_expiry.
    # underlying will return exit_tick preceding date_start
    return _data_disruption_error() if $contract->exit_tick and $contract->date_start->epoch > $contract->exit_tick->epoch;

    if ($contract->is_legacy) {
        return BOM::Pricing::v3::Utility::create_error({
            message_to_client => localize($contract->longcode),
            code              => "GetProposalFailure"
        });
    }

    return _data_disruption_error() if ((not $contract->may_settle_automatically) and $contract->missing_market_data);

    my $tv = [Time::HiRes::gettimeofday()];
    try {
        $params->{validation_params}->{landing_company} = $landing_company;

        my $valid_to_sell = _is_valid_to_sell($contract, $params->{validation_params}, $country_code);

        $response = _build_bid_response({
                contract         => $contract,
                contract_id      => $contract_id,
                is_valid_to_sell => $valid_to_sell->{is_valid_to_sell},
                is_sold          => $is_sold,
                is_expired       => $is_expired,
                sell_price       => $sell_price,
                sell_time        => $sell_time,
                validation_error => $valid_to_sell->{validation_error}});

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

sub localize_template_params {
    my $name = shift;
    if (ref $name eq 'ARRAY') {
        #Parms should be manually localized; otherwose they will be inserted into the template without localization.
        for (my $i = 1; $i <= $#$name; $i++) {
            localize_template_params($name->[$i]);
            $name->[$i] = localize($name->[$i]);
        }
    }
    return $name;
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

    # Here we have to do something like this because we are re-using
    # amout in the API for specifiying no of contracts.
    $params->{args}->{multiplier} //= $params->{args}->{amount} if (exists $params->{args}->{basis} and $params->{args}->{basis} eq 'multiplier');

    # copy country_code when it is available.
    $params->{args}->{country_code} = $params->{country_code} if $params->{country_code};

    # copy token_details when it is available.
    $params->{args}->{token_details} = $params->{token_details} if $params->{token_details};

    #Tactical solution, we will sort out api barrier entry validation
    #for all other contract types in a separate card and clean up this part.
    if (defined $params->{args}->{contract_type} and $params->{args}->{contract_type} =~ /RESET/ and defined $params->{args}->{barrier2}) {
        return BOM::Pricing::v3::Utility::create_error({
            code              => 'BarrierValidationError',
            message_to_client => localize("barrier2 is not allowed for reset contract."),
        });
    }

    my $response = try {
        _get_ask(prepare_ask($params->{args}), $params->{app_markup_percentage});
    }
    catch {
        _log_exception(send_ask => $_);
        BOM::Pricing::v3::Utility::create_error({
                code              => 'pricing error',
                message_to_client => localize('Unable to price the contract.')});
    };

    #price_stream_results_adjustment is based on theo_probability and is very binary-option specifics.
    #We do no have the concept of probabilty for the non binary options.
    $params->{args}->{skip_stream_results_adjustment} = $response->{contract_parameters}->{skip_stream_results_adjustment}
        if exists $response->{contract_parameters}->{skip_stream_results_adjustment};

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
        warn __PACKAGE__ . " get_contract_details produce_contract failed, parameters: " . $json->encode($bet_params);
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
    return $response if $contract->is_legacy;

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

    my $args            = $params->{args};
    my $symbol          = $args->{contracts_for};
    my $currency        = $args->{currency} || 'USD';
    my $landing_company = $args->{landing_company} // 'costarica';
    my $product_type    = $args->{product_type};
    my $country_code    = $params->{country_code} // '';

    my $token_details = $params->{token_details};

    if ($token_details and exists $token_details->{loginid}) {
        my $client = BOM::User::Client->new({
            loginid      => $token_details->{loginid},
            db_operation => 'replica',
        });
        # override the details here since we already have a client.
        $landing_company = $client->landing_company->short;
        $country_code    = $client->residence;
        $product_type //= $client->landing_company->default_offerings;
    }

    unless ($product_type) {
        $product_type = LandingCompany::Registry::get($landing_company)->default_offerings;
    }

    my $finder        = BOM::Product::ContractFinder->new;
    my $method        = $product_type eq 'basic' ? 'basic_contracts_for' : 'multi_barrier_contracts_for';
    my $contracts_for = $finder->$method({
        symbol          => $symbol,
        landing_company => $landing_company,
        country_code    => $country_code,
    });

    my $i = 0;
    foreach my $contract (@{$contracts_for->{available}}) {
        if (exists $contract->{payout_limit}) {
            $contracts_for->{available}->[$i]->{payout_limit} = $contract->{payout_limit}->{$currency};
        }
        $i++;
    }

    if (not $contracts_for or $contracts_for->{hit_count} == 0) {
        return BOM::Pricing::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize('Offering is unavailable on this symbol.')});
    } else {
        $contracts_for->{'spot'} = create_underlying($symbol)->spot();
        return $contracts_for;
    }

    return;
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
        warn __PACKAGE__ . " _get_ask produce_contract failed: $reason, parameters: " . $json->encode($args_copy);
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

sub _validate_offerings {
    my ($contract, $args_copy) = @_;

    my $response;

    my $token_details = $args_copy->{token_details};

    if ($token_details and exists $token_details->{loginid}) {
        my $client = BOM::User::Client->new({
            loginid      => $token_details->{loginid},
            db_operation => 'replica',
        });
        # override the details here since we already have a client
        $args_copy->{landing_company} = $client->landing_company->short;
        $args_copy->{country_code}    = $client->residence;
    }

    try {
        my $landing_company = LandingCompany::Registry::get($args_copy->{landing_company} // 'costarica');
        my $method = $contract->is_parameters_predefined ? 'multi_barrier_offerings_for_country' : 'basic_offerings_for_country';
        my $offerings_obj = $landing_company->$method(delete $args_copy->{country_code} // '', BOM::Config::Runtime->instance->get_offerings_config);

        die 'Could not find offerings for ' . $args_copy->{country_code} unless $offerings_obj;
        if (my $error = $offerings_obj->validate_offerings($contract->metadata($args_copy->{action}))) {
            $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'OfferingsValidationError',
                message_to_client => localize(@{$error->{message_to_client}}),
            });
        }
    }
    catch {
        my $message_to_client = _get_error_message($_, $args_copy);
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'OfferingsValidationFailure',
                message_to_client => localize(@$message_to_client)});
    };

    return $response;

}

=head2 _is_valid_to_sell

Checks if the contract is valid to sell back to Binary

    _is_valid_to_sell(12, \%validation_params, 'AU');

Takes the following arguments as parameters

=over 4

=item  contract L<BOM::Product::Contract>::* type of contract varies depending on bet type   

=item  validation_params A hashref  of attributes  used by the  contract validators in L<BOM::Product::ContractValidator>

=item  country_code  2 letter International Country Code. 

=back

Returns a hashref is_valid_to_sell = boolean , validation_error = String (validation error message )

=cut

sub _is_valid_to_sell {
    my ($contract, $validation_params, $country_code) = @_;
    my $is_valid_to_sell = 1;
    my $validation_error;

    if (
        not $contract->is_expired
        and my $cve = _validate_offerings(
            $contract,
            {
                landing_company => $validation_params->{landing_company},
                country_code    => $country_code,
                action          => 'sell'
            }))
    {
        $is_valid_to_sell = 0;
        $validation_error = localize($cve->{error}{message_to_client});
    } elsif (!$contract->is_valid_to_sell($validation_params->{validation_params})) {
        $is_valid_to_sell = 0;
        $validation_error = localize($contract->primary_validation_error->message_to_client);
    }
    return {
        is_valid_to_sell => $is_valid_to_sell,
        validation_error => $validation_error
    };
}

=head2 _build_bid_response

Description Builds the open contract response from the stored contract.

Takes the following arguments as named parameters

=over 4

=item contract L<BOM::Product::Contract>::* type of contract varies depending on bet type

=item contract_id  Integer internal identifier of the purchased Contract

=item is_valid_to_sell Boolean Whether the contract can be sold back to Binary.com. 

=item is_sold  Boolean  Whether the contract is sold or not.

=item is_expired  Boolean  Whether the contract is expired or not.

=item sell_price   Numeric Price at which contract was sold, only available when contract has been sold.

=item sell_time   Integer Epoch time of when the contract was sold (only present for contracts already sold).

=item validation_error  String   Message to be returned on a validation error. 

=back

Returns a contract proposal response as a  Hashref

=cut

sub _build_bid_response {
    my ($params) = @_;
    my $contract = $params->{contract};

    my $response = {
        is_valid_to_sell    => $params->{is_valid_to_sell},
        current_spot_time   => $contract->current_tick->epoch,
        contract_id         => $params->{contract_id},
        underlying          => $contract->underlying->symbol,
        display_name        => localize($contract->underlying->display_name),
        is_expired          => $contract->is_expired,
        is_forward_starting => $contract->is_forward_starting,
        is_path_dependent   => $contract->is_path_dependent,
        is_intraday         => $contract->is_intraday,
        date_start          => $contract->date_start->epoch,
        date_expiry         => $contract->date_expiry->epoch,
        date_settlement     => $contract->date_settlement->epoch,
        currency            => $contract->currency,
        longcode            => localize($contract->longcode),
        shortcode           => $contract->shortcode,
        contract_type       => $contract->code,
        bid_price           => formatnumber('price', $contract->currency, $contract->bid_price),
        is_settleable       => $contract->is_settleable,
        barrier_count       => $contract->two_barriers ? 2 : 1,
    };

    $response->{reset_time} = $contract->reset_spot->epoch if $contract->reset_spot;
    $response->{multiplier} = $contract->multiplier unless ($contract->is_binary);
    $response->{validation_error} = localize($params->{validation_error}) unless $params->{is_valid_to_sell};
    $response->{current_spot} = $contract->current_spot if $contract->underlying->feed_license eq 'realtime';
    $response->{tick_count}   = $contract->tick_count   if $contract->expiry_type eq 'tick';

    if ($contract->is_binary) {
        $response->{payout} = $contract->payout;
    } elsif ($contract->can('maximum_payout')) {
        $response->{payout} = $contract->maximum_payout;
    }

    if ($params->{is_sold} and $params->{is_expired}) {
        # here sell_price is used to parse the status of contracts that settled from Back Office
        # For non binary , there is no concept of won or lost, hence will return empty status if it is already expired and sold
        #$response->{status} = !$contract->is_binary ? undef : ($params->{sell_price} == $contract->payout ? "won" : "lost");
        $response->{status} = undef;
        if ($contract->is_binary) {
            $response->{status} = ($params->{sell_price} == $contract->payout ? "won" : "lost");
        }
    } elsif ($params->{is_sold} and not $params->{is_expired}) {
        $response->{status} = 'sold';
    } else {    # not sold
        $response->{status} = 'open';
    }

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

    if (    $contract->exit_tick
        and $contract->is_valid_exit_tick
        and $contract->is_after_settlement)
    {
        $response->{exit_tick}      = $contract->underlying->pipsized_value($contract->exit_tick->quote);
        $response->{exit_tick_time} = $contract->exit_tick->epoch;
    }

    if ($contract->is_settleable || $contract->is_sold) {
        my $localized_audit_details;
        my $ad = $contract->audit_details;
        foreach my $key (sort keys %$ad) {
            my @details = @{$ad->{$key}};
            foreach my $detail (@details) {
                if ($detail->{name}) {
                    my $name = $detail->{name};
                    localize_template_params($name);
                    $detail->{name} = localize($name);
                }
            }
            $localized_audit_details->{$key} = \@details;
        }
        $response->{audit_details} = $localized_audit_details;
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
    if ($params->{sell_time} and $params->{sell_time} < $contract->date_expiry->epoch) {
        if (    $contract->is_path_dependent
            and $contract->hit_tick
            and $contract->hit_tick->epoch <= $contract->date_expiry->epoch)
        {
            $contract_close_tick = $contract->hit_tick;
        }
        # client sold early
        $contract_close_tick = $contract->underlying->tick_at($params->{sell_time}, {allow_inconsistent => 1})
            unless defined $contract_close_tick;
    } elsif ($contract->is_expired) {
        # it could be that the contract is not sold until/after expiry for path dependent
        $contract_close_tick = $contract->hit_tick if $contract->is_path_dependent;
        $contract_close_tick = $contract->exit_tick if not $contract_close_tick and $contract->exit_tick;
    }

    # if the contract is still open, $contract_close_tick will be undefined
    if (defined $contract_close_tick) {
        foreach my $key ($params->{is_sold} ? qw(sell_spot exit_tick) : qw(exit_tick)) {
            $response->{$key} = $contract->underlying->pipsized_value($contract_close_tick->quote);
            $response->{$key . '_time'} = $contract_close_tick->epoch;
        }
    }

    return $response;
}
1;

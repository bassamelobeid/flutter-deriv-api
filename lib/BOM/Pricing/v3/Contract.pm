package BOM::Pricing::v3::Contract;

use strict;
use warnings;
no indirect;

use Scalar::Util qw(blessed);
use Syntax::Keyword::Try;
use List::MoreUtils qw(none);
use JSON::MaybeXS;
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use Time::HiRes;
use Time::Duration::Concise::Localize;
use BOM::User::Client;

use Format::Util::Numbers qw/formatnumber roundcommon/;
use Scalar::Util::Numeric qw(isint);

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Config;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Locale;
use BOM::Config::Runtime;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::ContractFinder;
use Finance::Contract::Longcode qw( shortcode_to_parameters);
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
            $args->{details} ? (details => $args->{details}) : (),
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
    } elsif (grep { /^(?:RUNHIGH|RUNLOW|RESETCALL|RESETPUT|(?:CALL|PUT)E?)$/ } @contract_types) {
        delete $p2{barrier2};
        # set to S0P if barrier is undef
        $p2{barrier} //= 'S0P';
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
        deep_otm_threshold    => $contract->otm_threshold,
        base_commission       => $contract->base_commission,
        min_commission_amount => $contract->min_commission_amount,
    };
}

sub _get_ask {
    my ($args_copy, $app_markup_percentage) = @_;
    my $streaming_params = delete $args_copy->{streaming_params};
    my ($contract, $response, $contract_parameters);

    my $tv = [Time::HiRes::gettimeofday];
    $args_copy->{app_markup_percentage} = $app_markup_percentage // 0;

    try {
        $contract = produce_contract($args_copy);
    } catch ($e) {
        my $message_to_client = _get_error_message($e, $args_copy);
        my $details           = _get_error_details($e);
        return BOM::Pricing::v3::Utility::create_error({
            code              => 'ContractCreationFailure',
            message_to_client => localize(@$message_to_client),
            $details ? (details => $details) : (),
        });
    }

    $response = _validate_offerings($contract, $args_copy);

    return $response if $response;

    try {
        $contract_parameters = {%$args_copy, %{contract_metadata($contract)}};
        my $country_code;
        if ($args_copy->{token_details} and exists $args_copy->{token_details}->{loginid}) {
            my $client = BOM::User::Client->new({
                loginid      => $args_copy->{token_details}->{loginid},
                db_operation => 'replica',
            });
            $country_code = $client->residence;
        }

        if (
            !(
                $contract->is_valid_to_buy({
                        landing_company => $args_copy->{landing_company},
                        country_code    => $country_code
                    })))
        {
            my ($message_to_client, $code, $details);

            if (my $pve = $contract->primary_validation_error) {
                $details           = $pve->details;
                $message_to_client = localize($pve->message_to_client);
                $code              = "ContractBuyValidationError";
            } else {
                $message_to_client = localize("Cannot validate contract.");
                $code              = "ContractValidationError";
            }

            $response = _create_error({
                message_to_client => $message_to_client,
                code              => $code,
                $details ? (details => $details) : (),
            });

            # proposal_array streaming could get error on a first call
            # but later could produce valid contract dependant on volatility moves
            # so we need to store contract_parameters and longcode to use them later
            if ($code eq 'ContractBuyValidationError') {
                my $longcode =
                    eval { $contract->longcode } || '';    # if we can't get the longcode that's fine, we still want to return the original error
                $response->{contract_parameters} = $contract_parameters;
                $response->{longcode}            = $longcode ? localize($longcode) : '';
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

            # We only want to return $response->{skip_streaming} from a valid RPC response
            unless ($streaming_params->{from_pricer}) {
                $response->{skip_streaming} = $contract->skip_streaming();
            }

            if (not $contract->is_binary) {
                $response->{contract_parameters}->{multiplier}        = $contract->multiplier        if not $contract->user_defined_multiplier;
                $response->{contract_parameters}->{maximum_ask_price} = $contract->maximum_ask_price if $contract->can('maximum_ask_price');
            }

            if ($contract->require_price_adjustment and $streaming_params->{from_pricer}) {
                if ($contract->is_binary) {
                    $response->{theo_probability} = $contract->theo_probability->amount;
                } else {
                    $response->{theo_price} = $contract->theo_price;
                }
            }

            if ($contract->underlying->feed_license eq 'realtime') {
                $response->{spot} = $contract->current_spot;
            }

            $response->{multiplier} = $contract->multiplier unless $contract->is_binary;

            if ($contract->category_code eq 'multiplier') {
                my $display = $contract->available_orders_for_display;
                $display->{$_}->{display_name} = localize($display->{$_}->{display_name}) for keys %$display;
                $response->{limit_order}       = $display;
                $response->{commission}        = $contract->commission_amount;                                  # commission in payout currency amount

                if ($contract->cancellation) {
                    $response->{cancellation} = {
                        ask_price   => $contract->cancellation_price,
                        date_expiry => $contract->cancellation_expiry->epoch,
                    };
                }
            }

            # On websocket, we are setting 'basis' to payout and 'amount' to 1000 to increase the collission rate.
            # This logic shouldn't be in websocket since it is business logic.
            unless ($streaming_params->{from_pricer}) {
                # To override multiplier or callputspread contracts (non-binary) just does not make any sense because
                # the ask_price is defined by the user and the output of limit order (take profit or stop out),
                # is dependent of the stake and multiplier provided by the client.
                # There is no probability calculation involved. Hence, not optimising anything.
                $response->{skip_basis_override} = 1 if $contract->code =~ /^(MULTUP|MULTDOWN|CALLSPREAD|PUTSPREAD)$/;
            }
        }
        my $pen = $contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.buy.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
    } catch ($e) {
        my $message_to_client = _get_error_message($e, $args_copy, 1);

        return BOM::Pricing::v3::Utility::create_error({
            message_to_client => localize(@$message_to_client),
            code              => "ContractCreationFailure"
        });
    }

    return $response;
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

    my ($contract, $bet_params);
    try {
        $bet_params = shortcode_to_parameters($short_code, $currency);
        $bet_params->{limit_order} = $params->{limit_order} if $params->{limit_order};
    } catch {
        warn __PACKAGE__ . " get_bid shortcode_to_parameters failed: $short_code, currency: $currency";

        return BOM::Pricing::v3::Utility::create_error({
                code              => 'GetProposalFailure',
                message_to_client => localize('Cannot create contract')});
    }

    try {
        $bet_params->{is_sold}               = $is_sold;
        $bet_params->{app_markup_percentage} = $app_markup_percentage // 0;
        $bet_params->{landing_company}       = $landing_company;
        $bet_params->{sell_time}             = $sell_time  if $is_sold;
        $bet_params->{sell_price}            = $sell_price if defined $sell_price;
        $contract                            = produce_contract($bet_params);
    } catch {
        warn __PACKAGE__ . " get_bid produce_contract failed, parameters: " . $json->encode($bet_params);

        return BOM::Pricing::v3::Utility::create_error({
                code              => 'GetProposalFailure',
                message_to_client => localize('Cannot create contract')});
    }

    if ($contract->is_legacy) {
        return BOM::Pricing::v3::Utility::create_error({
            message_to_client => localize($contract->longcode),
            code              => "GetProposalFailure"
        });
    }

    my $tv = [Time::HiRes::gettimeofday()];
    my $response;
    try {
        $params->{validation_params}->{landing_company} = $landing_company;

        my $valid_to_sell = _is_valid_to_sell($contract, $params->{validation_params}, $country_code);

        # we want to return immediately with a complete response in case of a data disruption because
        # we might now have a valid entry and exit tick.
        if (not $valid_to_sell->{is_valid_to_sell} and $contract->require_manual_settlement) {
            # can't just return the value when using Syntax::Keyword::Try, it breaks some tests
            # the response should be returned from outside of the try block
            $response = BOM::Pricing::v3::Utility::create_error({
                code              => "GetProposalFailure",
                message_to_client => $valid_to_sell->{validation_error},
            });
        } else {
            $response = _build_bid_response({
                contract           => $contract,
                contract_id        => $contract_id,
                is_valid_to_sell   => $valid_to_sell->{is_valid_to_sell},
                is_valid_to_cancel => $contract->is_valid_to_cancel,
                is_sold            => $is_sold,
                is_expired         => $is_expired,
                sell_price         => $sell_price,
                sell_time          => $sell_time,
                validation_error   => $valid_to_sell->{validation_error},
            });

            # (M)oved from bom-rpc populate_proposal_open_contract_response
            my ($transaction_ids, $buy_price, $account_id, $purchase_time) =
                @{$params}{qw/transaction_ids buy_price account_id purchase_time/};

            $response->{transaction_ids} = $transaction_ids if defined $transaction_ids;
            $response->{buy_price}       = $buy_price       if defined $buy_price;
            $response->{account_id}      = $account_id      if defined $account_id;
            $response->{is_sold}         = $is_sold         if defined $is_sold;
            $response->{sell_time}       = $sell_time       if defined $sell_time;
            $response->{purchase_time}   = $purchase_time   if defined $purchase_time;

            $response->{sell_price} = formatnumber('price', $currency, $sell_price)
                if defined $sell_price;

            if (defined $response->{buy_price}
                and (defined $response->{bid_price} or defined $response->{sell_price}))
            {
                my $cancellation_price  = $response->{cancellation} ? $response->{cancellation}->{ask_price} : 0;
                my $main_contract_price = $response->{buy_price} - $cancellation_price;
                my $profit              = ($response->{sell_price} // $response->{bid_price}) - $main_contract_price;

                $response->{profit}            = formatnumber('price', $currency, $profit);
                $response->{profit_percentage} = roundcommon(0.01, $profit / $main_contract_price * 100);
            }
            # (M)

            my $pen = $contract->pricing_engine_name;
            $pen =~ s/::/_/g;
            stats_timing('compute_price.sell.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
        }
    } catch ($e) {
        _log_exception(get_bid => $e);

        return BOM::Pricing::v3::Utility::create_error({
            message_to_client => localize('Sorry, an error occurred while processing your request.'),
            code              => "GetProposalFailure"
        });
    }
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
    my $params   = shift;
    my $tv       = [Time::HiRes::gettimeofday];
    my $response = undef;

    try {
        $response = get_bid($params);
    } catch ($e) {
        # This should be impossible: get_bid() has an exception wrapper around
        # all the useful code, so unless the error creation or localize steps
        # fail, there's not much else that can go wrong. We therefore log and
        # report anyway.

        _log_exception(send_bid => "$e (and it should be impossible for this to happen)");

        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'pricing error',
                message_to_client => localize('Unable to price the contract.')});
    }

    $response->{rpc_time} = 1000 * Time::HiRes::tv_interval($tv);

    return $response;
}

sub send_ask {
    my $params = shift;

    my $tv = [Time::HiRes::gettimeofday];

    # provide landing_company information when it is available.
    $params->{args}->{landing_company} = $params->{landing_company}
        if $params->{landing_company};

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
            details           => {field => 'barrier2'},
        });
    }

    my $response;
    try {
        $response = _get_ask(prepare_ask($params->{args}), $params->{app_markup_percentage});
    } catch ($e) {
        _log_exception(send_ask => $e);
        $response = BOM::Pricing::v3::Utility::create_error({
                code              => 'pricing error',
                message_to_client => localize('Unable to price the contract.')});
    }

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
        if ($bet_params->{bet_type} =~ /^(?:MULTUP|MULTDOWN)$/) {
            my $poc_parameters = BOM::Pricing::v3::Utility::get_poc_parameters($params->{contract_id}, $params->{landing_company});
            $bet_params->{limit_order} = $poc_parameters->{limit_order};
        }
    } catch {
        warn __PACKAGE__ . " get_contract_details shortcode_to_parameters failed: $params->{short_code}, currency: $params->{currency}";

        return BOM::Pricing::v3::Utility::create_error({
                code              => 'GetContractDetails',
                message_to_client => localize('Cannot create contract')});
    }

    try {
        $bet_params->{app_markup_percentage} = $params->{app_markup_percentage} // 0;
        $bet_params->{landing_company}       = $params->{landing_company};
        $bet_params->{limit_order}           = $params->{limit_order} if $params->{limit_order};
        $contract                            = produce_contract($bet_params);
    } catch {
        warn __PACKAGE__ . " get_contract_details produce_contract failed, parameters: " . $json->encode($bet_params);

        return BOM::Pricing::v3::Utility::create_error({
                code              => 'GetContractDetails',
                message_to_client => localize('Cannot create contract')});
    }

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
    } elsif ($contract->can('barrier')) {
        $response->{barrier} = $contract->barrier ? $contract->barrier->supplied_barrier : undef;
    } elsif ($contract->category_code eq 'multiplier') {
        foreach my $order (@{$contract->supported_orders}) {
            $response->{$order} = $contract->$order->barrier_value if $contract->$order and $contract->$order->barrier_value;
        }
    }

    return $response;
}

sub contracts_for {
    my $params = shift;

    my $args            = $params->{args};
    my $symbol          = $args->{contracts_for};
    my $currency        = $args->{currency} || 'USD';
    my $landing_company = $args->{landing_company} // 'virtual';
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
    }

    $product_type //= LandingCompany::Registry::get($landing_company)->default_product_type;

    #Preparing error handler;
    my $get_invalid_symbol_error = sub {
        BOM::Pricing::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize('This contract is not offered in your country.')});
    };

    return $get_invalid_symbol_error->() unless $product_type;

    my $invalid_currency = BOM::Platform::Client::CashierValidation::invalid_currency_error($currency);
    return BOM::Pricing::v3::Utility::create_error($invalid_currency) if $invalid_currency;

    my $finder = BOM::Product::ContractFinder->new;

    my $contracts_for = $finder->basic_contracts_for({
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

    return $get_invalid_symbol_error->()
        if !$contracts_for || $contracts_for->{hit_count} == 0;

    $contracts_for->{'spot'} = create_underlying($symbol)->spot();
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

sub _get_error_details {
    my $reason = shift;

    return $reason->details   if (blessed($reason) && $reason->isa('BOM::Product::Exception'));
    return $reason->{details} if ref($reason) eq 'HASH';

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

sub _validate_offerings {
    my ($contract, $args_copy) = @_;

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
        my $landing_company = LandingCompany::Registry::get($args_copy->{landing_company} // 'virtual');

        my $offerings_obj = $landing_company->basic_offerings_for_country(delete $args_copy->{country_code} // '',
            BOM::Config::Runtime->instance->get_offerings_config($args_copy->{action}));

        die 'Could not find offerings for ' . $args_copy->{country_code} unless $offerings_obj;
        if (my $error = $offerings_obj->validate_offerings($contract->metadata($args_copy->{action}))) {
            my $details = _get_error_details($error);

            return BOM::Pricing::v3::Utility::create_error({
                code              => 'OfferingsValidationError',
                message_to_client => localize(@{$error->{message_to_client}}),
                $details ? (details => $details) : (),
            });
        }
    } catch ($e) {
        my $message_to_client = _get_error_message($e, $args_copy);
        my $details           = _get_error_details($e);

        return BOM::Pricing::v3::Utility::create_error({
            code              => 'OfferingsValidationFailure',
            message_to_client => localize(@$message_to_client),
            $details ? (details => $details) : (),
        });
    }
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

my @spot_list = qw(entry_tick entry_spot exit_tick sell_spot current_spot);

sub _build_bid_response {
    my ($params)           = @_;
    my $contract           = $params->{contract};
    my $is_valid_to_settle = $contract->is_settleable;

    # "0 +" converts string into number. This was added to ensure some fields return the value as number instead of string
    my $response = {
        is_valid_to_sell    => $params->{is_valid_to_sell},
        current_spot_time   => 0 + $contract->current_tick->epoch,
        contract_id         => $params->{contract_id},
        underlying          => $contract->underlying->symbol,
        display_name        => localize($contract->underlying->display_name),
        is_expired          => $contract->is_expired,
        is_forward_starting => $contract->starts_as_forward_starting,
        is_path_dependent   => $contract->is_path_dependent,
        is_intraday         => $contract->is_intraday,
        date_start          => 0 + $contract->date_start->epoch,
        date_expiry         => 0 + $contract->date_expiry->epoch,
        date_settlement     => 0 + $contract->date_settlement->epoch,
        currency            => $contract->currency,
        longcode            => localize($contract->longcode),
        shortcode           => $contract->shortcode,
        contract_type       => $contract->code,
        bid_price           => formatnumber('price', $contract->currency, $contract->bid_price),
        is_settleable       => $is_valid_to_settle,
        barrier_count       => $contract->two_barriers ? 2 : 1,
        is_valid_to_cancel  => $params->{is_valid_to_cancel},
        expiry_time         => $contract->date_expiry->epoch,
    };
    if (!$contract->uses_barrier) {
        $response->{barrier_count} = 0;
        $response->{barrier}       = undef;
    }
    $response->{reset_time}       = 0 + $contract->reset_spot->epoch if $contract->reset_spot;
    $response->{multiplier}       = $contract->multiplier                 unless ($contract->is_binary);
    $response->{validation_error} = localize($params->{validation_error}) unless $params->{is_valid_to_sell};
    $response->{current_spot}     = $contract->current_spot if $contract->underlying->feed_license eq 'realtime';
    $response->{tick_count}       = $contract->tick_count   if $contract->expiry_type eq 'tick';

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

    # overwrite the above status if contract is cancelled
    $response->{status} = 'cancelled' if $contract->is_cancelled;

    if ($contract->entry_spot) {
        my $entry_spot = $contract->underlying->pipsized_value($contract->entry_spot);
        $response->{entry_tick}      = $entry_spot;
        $response->{entry_spot}      = $entry_spot;
        $response->{entry_tick_time} = 0 + $contract->entry_spot_epoch;
    }

    if ($contract->two_barriers) {
        if ($contract->high_barrier->supplied_type eq 'absolute') {
            $response->{high_barrier} = $contract->high_barrier->as_absolute;
            $response->{low_barrier}  = $contract->low_barrier->as_absolute;
        } elsif ($contract->entry_spot) {
            # supplied_type 'difference' and 'relative' will need entry spot
            # to calculate absolute barrier value
            $response->{high_barrier} = $contract->high_barrier->as_absolute;
            $response->{low_barrier}  = $contract->low_barrier->as_absolute;
        }
    } elsif ($contract->can('barrier') and $contract->barrier) {
        if ($contract->barrier->supplied_type eq 'absolute' or $contract->barrier->supplied_type eq 'digit') {
            $response->{barrier} = $contract->barrier->as_absolute;
        } elsif ($contract->entry_spot) {
            $response->{barrier} = $contract->barrier->as_absolute;
        }
    }

    # for multiplier, we want to return the orders and insurance details.
    if ($contract->category_code eq 'multiplier') {
        # If the caller is not from price daemon, we need:
        # 1. sorted orders as array reference ($contract->available_orders) for PRICER_ARGS
        # 2. available order for display in the websocket api response ($contract->available_orders_for_display)
        my $display = $contract->available_orders_for_display;
        $display->{$_}->{display_name} = localize($display->{$_}->{display_name}) for keys %$display;
        $response->{limit_order} = $display;
        # commission in payout currency amount
        $response->{commission} = $contract->commission_amount;
        # deal cancellation
        if ($contract->cancellation) {
            $response->{cancellation} = {
                ask_price   => $contract->cancellation_price,
                date_expiry => $contract->cancellation_expiry->epoch,
            };
        }
    }

    if (    $contract->exit_tick
        and $contract->is_valid_exit_tick
        and $contract->is_after_settlement)
    {
        $response->{exit_tick}      = $contract->underlying->pipsized_value($contract->exit_tick->quote);
        $response->{exit_tick_time} = 0 + $contract->exit_tick->epoch;
    }

    if ($is_valid_to_settle || $contract->is_sold) {
        my $localized_audit_details;
        my $ad = $contract->audit_details($params->{sell_time});
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
            and $contract->close_tick
            and $contract->close_tick->epoch <= $params->{sell_time})
        {
            $contract_close_tick = $contract->close_tick;
        }
        # client sold early
        $contract_close_tick = $contract->underlying->tick_at($params->{sell_time}, {allow_inconsistent => 1})
            unless defined $contract_close_tick;
    } elsif ($contract->is_expired) {
        # it could be that the contract is not sold until/after expiry for path dependent
        $contract_close_tick = $contract->close_tick if $contract->is_path_dependent;
        $contract_close_tick = $contract->exit_tick  if not $contract_close_tick and $contract->exit_tick and $contract->is_valid_exit_tick;
    }

    # if the contract is still open, $contract_close_tick will be undefined
    if (defined $contract_close_tick) {
        foreach my $key ($params->{is_sold} ? qw(sell_spot exit_tick) : qw(exit_tick)) {
            $response->{$key} = $contract->underlying->pipsized_value($contract_close_tick->quote);
            $response->{$key . '_time'} = 0 + $contract_close_tick->epoch;
        }
    }

    if ($contract->tick_expiry) {

        $response->{tick_stream} = $contract->tick_stream;
    }

    $response->{$_ . '_display_value'} = $contract->underlying->pipsized_value($response->{$_}) for (grep { defined $response->{$_} } @spot_list);
    # makes sure they are numbers
    $response->{$_} += 0 for (grep { defined $response->{$_} } @spot_list);

    return $response;
}

1;

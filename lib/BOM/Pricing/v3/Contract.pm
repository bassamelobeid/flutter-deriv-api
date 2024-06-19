package BOM::Pricing::v3::Contract;

use strict;
use warnings;
no indirect;

use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Contract::Factory qw(produce_contract);
use BOM::Contract::Pricer;
use BOM::Contract::Validator;
use BOM::Pricing::v3::Utility;
use BOM::User::Client;
use DataDog::DogStatsd::Helper  qw(stats_timing stats_inc);
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use Format::Util::Numbers       qw/formatnumber roundcommon/;
use JSON::MaybeXS;
use LandingCompany::Registry;
use Scalar::Util qw(blessed);
use Syntax::Keyword::Try;
use Time::HiRes;

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

    foreach my $type (@contract_types) {
        if ($type) {
            $p2{next_tick_execution} = 1 if $type =~ /MULTUP|MULTDOWN/;
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

sub _get_ask {
    my ($args_copy, $app_markup_percentage) = @_;
    my $streaming_params = delete $args_copy->{streaming_params};
    my ($contract, $response);
    my $country_code;

    my $tv = [Time::HiRes::gettimeofday];
    $args_copy->{app_markup_percentage} = $app_markup_percentage // 0;

    try {
        $contract     = produce_contract($args_copy);
        $country_code = $args_copy->{country_code}
    } catch ($e) {
        my $message_to_client = _get_error_message($e, $args_copy);
        my $details           = _get_error_details($e);
        return BOM::Pricing::v3::Utility::create_error({
            code              => 'ContractCreationFailure',
            message_to_client => $message_to_client,
            $details ? (details => $details) : (),
        });
    }

    $response = _validate_offerings($contract, $args_copy);

    return $response if $response;

    try {
        if ($args_copy->{token_details} and exists $args_copy->{token_details}->{loginid}) {
            my $client = BOM::User::Client->new({
                loginid      => $args_copy->{token_details}->{loginid},
                db_operation => 'replica',
            });
            $country_code = $client->residence;
        }
        my ($valid_to_buy, $pve) = BOM::Contract::Validator->is_valid_to_buy(
            $contract,
            {
                landing_company => $args_copy->{landing_company},
                country_code    => $country_code,
            });

        if (!$valid_to_buy) {
            my ($message_to_client, $code, $details);

            if ($pve) {
                $details           = $pve->details;
                $message_to_client = $pve->message_to_client;
                $code              = "ContractBuyValidationError";
            } else {
                $message_to_client = "Cannot validate contract.";
                $code              = "ContractValidationError";
            }

            $response = _create_error({
                message_to_client => $message_to_client,
                code              => $code,
                $details ? (details => $details) : (),
            });
        } else {
            # We think this contract is valid to buy
            $response = BOM::Contract::Pricer->calc_ask_price_detailed(
                $contract,
                {
                    update => $streaming_params->{from_pricer},
                });
            for my $k (keys %$args_copy) {
                $response->{contract_parameters}{$k} = $args_copy->{$k} unless exists $response->{contract_parameters}{$k};
            }
            if ($streaming_params->{from_pricer}) {
                delete $response->{skip_streaming};
            }
        }
        my $pen = $contract->inner_contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.buy.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
    } catch ($e) {
        my $message_to_client = _get_error_message($e, $args_copy, 1);

        return BOM::Pricing::v3::Utility::create_error({
            message_to_client => $message_to_client,
            code              => "ContractCreationFailure",
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

    my ($short_code, $contract_id, $currency, $is_sold, $is_expired, $sell_time, $sell_price, $app_markup_percentage, $landing_company, $country_code)
        = @{$params}{qw/short_code contract_id currency is_sold is_expired sell_time sell_price app_markup_percentage landing_company country_code/};

    my ($contract, $bet_params);
    try {
        $bet_params = shortcode_to_parameters($short_code, $currency);
        $bet_params->{limit_order} = $params->{limit_order} if $params->{limit_order};
    } catch {
        warn __PACKAGE__ . " get_bid shortcode_to_parameters failed: $short_code, currency: $currency";

        return BOM::Pricing::v3::Utility::create_error({
            code              => 'GetProposalFailure',
            message_to_client => 'Cannot create contract',
        });
    }

    try {
        $bet_params->{is_sold}               = $is_sold;
        $bet_params->{app_markup_percentage} = $app_markup_percentage // 0;
        $bet_params->{landing_company}       = $landing_company;
        $bet_params->{sell_time}             = $sell_time              if $is_sold;
        $bet_params->{sell_price}            = $sell_price             if defined $sell_price;
        $bet_params->{current_tick}          = $params->{current_tick} if $params->{current_tick};
        $contract                            = produce_contract($bet_params);
    } catch {
        warn __PACKAGE__ . " get_bid produce_contract failed, parameters: " . $json->encode($bet_params);

        return BOM::Pricing::v3::Utility::create_error({
            code              => 'GetProposalFailure',
            message_to_client => 'Cannot create contract',
        });
    }

    if (BOM::Contract::Validator->is_legacy($contract)) {
        return BOM::Pricing::v3::Utility::create_error({
            message_to_client => $contract->longcode,
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
        if (not $valid_to_sell->{is_valid_to_sell} and $contract->inner_contract->require_manual_settlement) {
            # can't just return the value when using Syntax::Keyword::Try, it breaks some tests
            # the response should be returned from outside of the try block
            $response = BOM::Pricing::v3::Utility::create_error({
                code              => "GetProposalFailure",
                message_to_client => $valid_to_sell->{validation_error},
            });
        } else {
            $response = BOM::Contract::Pricer->calc_bid_price_detailed(
                $contract,
                {
                    is_sold    => $is_sold,
                    is_expired => $is_expired,
                    sell_price => $sell_price,
                    sell_time  => $sell_time,
                });
            $response->{is_valid_to_sell} = $valid_to_sell->{is_valid_to_sell} ? 1 : 0;
            unless ($valid_to_sell->{is_valid_to_sell}) {
                $response->{validation_error}      = $valid_to_sell->{validation_error};
                $response->{validation_error_code} = $valid_to_sell->{validation_error_code};
            }
            $response->{contract_id} = $contract_id;

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

            my $pen = $contract->inner_contract->pricing_engine_name;
            $pen =~ s/::/_/g;
            stats_timing('compute_price.sell.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
        }
    } catch ($e) {
        _log_exception(get_bid => $e);

        return BOM::Pricing::v3::Utility::create_error({
            message_to_client => 'Sorry, an error occurred while processing your request.',
            code              => "GetProposalFailure"
        });
    }

    return $response;
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
            message_to_client => 'Unable to price the contract.',
        });
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
            message_to_client => "barrier2 is not allowed for reset contract.",
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
                message_to_client => 'Unable to price the contract.',
            },
        );
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
        if ($bet_params->{bet_type} =~ /^(?:MULTUP|MULTDOWN|ACCU)$/) {
            my $poc_parameters = BOM::Pricing::v3::Utility::get_poc_parameters($params->{contract_id}, $params->{landing_company});
            $bet_params->{limit_order} = $poc_parameters->{limit_order};
        }
    } catch {
        warn __PACKAGE__ . " get_contract_details shortcode_to_parameters failed: $params->{short_code}, currency: $params->{currency}";

        return BOM::Pricing::v3::Utility::create_error({
            code              => 'GetContractDetails',
            message_to_client => 'Cannot create contract',
        });
    }

    try {
        $bet_params->{app_markup_percentage} = $params->{app_markup_percentage} // 0;
        $bet_params->{landing_company}       = $params->{landing_company};
        $bet_params->{limit_order}           = $params->{limit_order} if $params->{limit_order};
        $contract                            = produce_contract($bet_params)->inner_contract;
    } catch {
        warn __PACKAGE__ . " get_contract_details produce_contract failed, parameters: " . $json->encode($bet_params);

        return BOM::Pricing::v3::Utility::create_error({
            code              => 'GetContractDetails',
            message_to_client => 'Cannot create contract',
        });
    }

    $response = {
        longcode     => $contract->longcode,
        symbol       => $contract->underlying->symbol,
        display_name => $contract->underlying->display_name,
        date_expiry  => $contract->date_expiry->epoch
    };

    # do not have any other information on legacy contract
    return $response if $contract->is_legacy;

    if ($contract->two_barriers and $contract->high_barrier and $contract->low_barrier) {
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
        _log_exception(_get_ask => $reason . "parameters: " . $json->encode($args_copy));
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
        my $landing_company = LandingCompany::Registry->by_name($args_copy->{landing_company}                 // 'virtual');
        my $offerings_obj   = $landing_company->basic_offerings_for_country(delete $args_copy->{country_code} // '',
            BOM::Config::Runtime->instance->get_offerings_config($args_copy->{action}));

        die 'Could not find offerings for ' . $args_copy->{country_code} unless $offerings_obj;
        if (my $error = $offerings_obj->validate_offerings($contract->metadata($args_copy->{action}))) {
            my $details = _get_error_details($error);

            return BOM::Pricing::v3::Utility::create_error({
                code              => 'OfferingsValidationError',
                message_to_client => $error->{message_to_client},
                $details ? (details => $details) : (),
            });
        }
    } catch ($e) {
        my $message_to_client = _get_error_message($e, $args_copy);
        my $details           = _get_error_details($e);

        return BOM::Pricing::v3::Utility::create_error({
            code              => 'OfferingsValidationFailure',
            message_to_client => $message_to_client,
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
    my ($valid_to_sell, $pve) = BOM::Contract::Validator->is_valid_to_sell(
        $contract,
        {
            landing_company         => $validation_params->{landing_company},
            country_code            => $country_code,
            skip_barrier_validation => $validation_params->{skip_barrier_validation},
        },
    );
    if (!$valid_to_sell) {
        return {
            is_valid_to_sell      => undef,
            validation_error      => $pve->message_to_client,
            validation_error_code => $pve->code,
        };
    }

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
        return {
            is_valid_to_sell      => undef,
            validation_error      => $cve->{error}{message_to_client},
            validation_error_code => 'Offerings',
        };
    }

    return {
        is_valid_to_sell => 1,
    };
}

1;

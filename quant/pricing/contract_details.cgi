#!/etc/rmg/bin/perl

=head1 NAME

Contract's pricing details

=head1 DESCRIPTION

A b/o tool that output contract's pricing parameters that will be used to replicate the contract price with an excel template.
This is a Japanese regulatory requirements.

=cut

package main;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use Format::Util::Numbers qw(roundnear);
use Price::RoundPrecision::JPY;
use f_brokerincludeall;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::Pricing::Engine::Intraday::Forex;
use BOM::Database::ClientDB;
use Client::Account;
use BOM::Database::DataMapper::Transaction;
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel);
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use LandingCompany::Registry;
BOM::Backoffice::Sysinit::init();
BOM::Backoffice::Auth0::can_access(['Quants']);
my %params = %{request()->params};
my ($pricing_parameters, @contract_details, $start);

my $broker        = $params{broker}     // request()->broker_code;
my $id            = $params{id}         // '';
my $short_code    = $params{short_code} // '';
my $currency_code = $params{currency}   // '';

if ($broker and ($id or $short_code)) {

    my ($details, $client);

    if ($id) {
        $details = BOM::Database::DataMapper::Transaction->new({
                broker_code => $broker,
                operation   => 'backoffice_replica',
            })->get_details_by_transaction_ref($id);

        $client = Client::Account::get_instance({'loginid' => $details->{loginid}});

    }

    my $short_code_param = $details->{shortcode}     // $short_code;
    my $currency_param   = $details->{currency_code} // $currency_code;

    my $original_contract = produce_contract($short_code_param, $currency_param);
    my $action_type = $details->{action_type} // 'buy';    #If it is with shortcode as input, we just want to verify the ask price
    my $sell_time = $details->{sell_time};
    my $purchase_time = $details->{purchase_time} // $original_contract->date_start;
    my $landing_company = defined $client ? $client->landing_company->short : LandingCompany::Registry::get_by_broker($broker)->short;

    $start =
          $params{start}          ? Date::Utility->new($params{start})
        : ($action_type eq 'buy') ? Date::Utility->new($purchase_time)
        :                           Date::Utility->new($sell_time);

    my $pricing_args = $original_contract->build_parameters;
    $pricing_args->{date_pricing}    = $start;
    $pricing_args->{landing_company} = $landing_company;

    my $contract               = produce_contract($pricing_args);
    my $display_price          = $action_type eq 'buy' ? $contract->ask_price : $contract->bid_price;
    my $prev_tick              = $contract->underlying->tick_at($start->epoch - 1, {allow_inconsistent => 1})->quote;
    my $traded_contract        = $action_type eq 'buy' ? $contract : $contract->opposite_contract;
    my $discounted_probability = $contract->discounted_probability;

    $pricing_parameters =
        $contract->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Forex'
        ? _get_pricing_parameter_from_IH_pricer($traded_contract, $action_type, $discounted_probability)
        : $contract->pricing_engine_name eq 'Pricing::Engine::EuropeanDigitalSlope'
        ? _get_pricing_parameter_from_slope_pricer($traded_contract, $action_type, $discounted_probability)
        : $contract->pricing_engine_name eq 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated'
        ? _get_pricing_parameter_from_vv_pricer($traded_contract, $action_type, $discounted_probability)
        : die "Can not obtain pricing parameter for this contract with pricing engine: $contract->pricing_engine_name \n";

    @contract_details = (
        login_id => $details->{loginid} // 'NA.',
        trans_id => $id // 'NA.',
        short_code             => $contract->shortcode,
        description            => $contract->longcode,
        ccy                    => $contract->currency,
        order_type             => $action_type,
        order_price            => $details->{order_price} // $display_price,
        slippage_price         => $details->{price_slippage} // 'NA.',
        trade_ask_price        => $details->{ask_price} // 'NA.',
        trade_bid_price        => $details->{bid_price} // 'NA. (unsold)',
        payout                 => $contract->payout,
        tick_before_trade_time => $prev_tick,
        ref_spot               => $details->{pricing_spot},
        ref_vol                => $details->{high_barrier_vol},                #it will be the vol of barrier for the single barrier contract
        ref_vol_2              => $details->{low_barrier_vol});
}
my $display = $params{download} ? 'download' : 'display';
if ($display eq 'download') {
    output_as_csv($pricing_parameters, \@contract_details);
    return;
}

PrintContentType();
BrokerPresentation("Contract's details");
Bar("Contract's Parameters");

sub output_as_csv {
    my $param            = shift;
    my $contract_details = shift;
    my $loginid          = $contract_details->[1];
    my $trans_id         = $contract_details->[3];
    my $csv_name         = $loginid . '_' . $trans_id . '.csv';
    PrintContentType_excel($csv_name);
    my $size = scalar @$contract_details;
    for (my $i = 0; $i <= $size; $i = $i + 2) {
        print uc($contract_details->[$i]) . " " . $contract_details->[$i + 1] . "\n";
    }
    foreach my $key (keys %{$param}) {
        print uc($key) . "\n";
        foreach my $subkey (keys %{$param->{$key}}) {
            if ($key ne 'numeraire_probability') {
                print "$subkey " . $param->{$key}->{$subkey} . "\n";
            }
            {
                foreach my $subsubkey (keys %{$param->{$key}->{$subkey}}) {
                    print "$subkey $subsubkey " . $param->{$key}->{$subkey}->{$subsubkey} . "\n";
                }
            }
        }
        print "\n";
    }

}

sub _get_pricing_parameter_from_IH_pricer {
    my ($contract, $action_type, $discounted_probability) = @_;
    my $pricing_parameters;

    my $pe                = $contract->pricing_engine;
    my $bs_probability    = $pe->base_probability->base_amount;
    my $commission_markup = $contract->commission_markup->amount;

    if ($action_type eq 'sell') {
        $pricing_parameters->{bid_probability} = {
            discounted_probability            => $discounted_probability->amount,
            opposite_contract_ask_probability => $contract->ask_probability->amount
        };

        $pricing_parameters->{opposite_contract_ask_probability} = {
            bs_probability    => $bs_probability,
            commission_markup => $commission_markup,
            map { $_ => $pe->$_->amount } qw(intraday_delta_correction intraday_vega_correction risk_markup),
        };

    } else {
        $pricing_parameters->{ask_probability} = {
            bs_probability    => $bs_probability,
            commission_markup => $commission_markup,
            map { $_ => $pe->$_->amount } qw(intraday_delta_correction intraday_vega_correction risk_markup),
        };
    }
    my @bs_keys = ('S', 'K', 't', 'discount_rate', 'mu', 'vol');
    my @formula_args = $pe->_formula_args;
    $pricing_parameters->{bs_probability} = {
        payout => $contract->payout,
        map { $bs_keys[$_] => $formula_args[$_] } 0 .. $#bs_keys
    };

    $pricing_parameters->{intraday_vega_correction} = {
        historical_vol_mean_reversion => BOM::System::Config::quants->{commission}->{intraday}->{historical_vol_meanrev},
        map { $_ => $pe->$_->amount } qw(intraday_vega long_term_prediction),
    };

    my $intraday_delta_correction = $pe->intraday_delta_correction;
    $pricing_parameters->{intraday_delta_correction} = {
          short_term_delta_correction => $contract->get_time_to_expiry->minutes < 10 ? $pe->_get_short_term_delta_correction
        : $contract->get_time_to_expiry->minutes > 20 ? 0
        : $intraday_delta_correction->peek_amount('delta_correction_short_term_value'),
        long_term_delta_correction => $contract->get_time_to_expiry->minutes > 20 ? $pe->_get_long_term_delta_correction
        : $contract->get_time_to_expiry->minutes < 10 ? 0
        :                                               $intraday_delta_correction->peek_amount('delta_correction_long_term_value'),
    };

    $pricing_parameters->{commission_markup} = {
        base_commission       => $contract->base_commission,
        commission_multiplier => $contract->commission_multiplier($contract->payout),
    };

    my $risk_markup = $pe->risk_markup;
    $pricing_parameters->{risk_markup} = {
        map { $_ => $risk_markup->peek_amount($_) // 0 }
            qw(economic_events_markup intraday_historical_iv_risk quiet_period_markup vol_spread_markup intraday_eod_markup spot_jump_markup short_term_kurtosis_risk_markup),

    };

    return $pricing_parameters;

}

sub _get_pricing_parameter_from_vv_pricer {
    my ($contract, $action_type, $discounted_probability) = @_;

    my $pe = $contract->pricing_engine;
    my $pricing_parameters;
    my $risk_markup       = $contract->risk_markup->amount;
    my $commission_markup = $contract->commission_markup->amount;
    my $theo_probability  = $pe->base_probability->amount;

    if ($action_type eq 'sell') {
        $pricing_parameters->{bid_probability} = {
            discounted_probability            => $discounted_probability->amount,
            opposite_contract_ask_probability => $contract->ask_probability->amount
        };

        $pricing_parameters->{opposite_contract_ask_probability} = {
            theoretical_probability => $theo_probability,
            risk_markup             => $risk_markup,
            commission_markup       => $commission_markup,

        };

    } else {

        $pricing_parameters->{ask_probability} = {
            theoretical_probability => $theo_probability,
            risk_markup             => $risk_markup,
            commission_markup       => $commission_markup,
        };
    }

    $pricing_parameters->{theoretical_probability} = {
        bs_probability    => $pe->bs_probability->amount,
        market_supplement => $pe->market_supplement->amount,
    };
    my $pricing_arg = $contract->pricing_args;
    $pricing_parameters->{bs_probability} = {
        'S'      => $pricing_arg->{spot},
        'K'      => $pricing_arg->{barrier1},
        'vol'    => $pricing_arg->{iv},
        'payout' => $contract->payout,
        map { $_ => $pricing_arg->{$_} } qw(t discount_rate mu)
    };

    $pricing_parameters->{bs_probability}->{'K2'} = $pricing_arg->{barrier2} if $contract->two_barriers;

    $pricing_parameters->{market_supplement} = _get_market_supplement_parameters($pe);

    $pricing_parameters->{commission_markup} = {
        base_commission       => $contract->base_commission,
        commission_multiplier => $contract->commission_multiplier($contract->payout),

    };

    my $risk_markup = $pe->risk_markup;
    $pricing_parameters->{risk_markup} = {
        map { $_ => $risk_markup->peek_amount($_) // 0 }
            qw(vol_spread_markup vol_spread bet_vega spot_spread_markup bet_delta spot_spread forward_start eod_market_risk_markup butterfly_markup butterfly_greater_than_cutoff spread_to_markup),

    };

    return $pricing_parameters;
}

sub _get_pricing_parameter_from_slope_pricer {
    my ($contract, $action_type, $discounted_probability) = @_;

    my $pe                = $contract->pricing_engine;
    my $debug_information = $pe->debug_information;
    my $pricing_parameters;
    my $contract_type     = $pe->contract_type;
    my $risk_markup       = $contract->risk_markup->amount;
    my $commission_markup = $contract->commission_markup->amount;
    my $ask_price         = $contract->ask_price;
    if ($action_type eq 'sell') {
        $pricing_parameters->{bid_probability} = {
            discounted_probability            => $discounted_probability->amount,
            opposite_contract_ask_probability => $contract->ask_probability->amount
        };

        $pricing_parameters->{opposite_contract_ask_probability} = {
            theoretical_probability => $pe->base_probability,
            risk_markup             => $risk_markup,
            commission_markup       => $commission_markup,

        };

    } else {

        $pricing_parameters->{ask_probability} = {
            theoretical_probability => $pe->base_probability,
            risk_markup             => $risk_markup,
            commission_markup       => $commission_markup,
        };
    }

    my $theo_param            = $debug_information->{$contract_type}{base_probability}{parameters};
    my $display_contract_type = lc($contract_type);

    if (not $contract->two_barriers) {
        if ($contract->priced_with eq 'base') {
            $pricing_parameters->{bs_probability} =
                _get_bs_probability_parameters($theo_param->{numeraire_probability}{parameters}{bs_probability}{parameters},
                $contract->payout, $display_contract_type);
            my $slope_param = $theo_param->{numeraire_probability}{parameters}{slope_adjustment}{parameters};
            $pricing_parameters->{slope_adjustment} = _get_slope_parameters($slope_param, $display_contract_type);
        } else {
            $pricing_parameters->{bs_probability} =
                _get_bs_probability_parameters($theo_param->{bs_probability}{parameters}, $contract->payout, $display_contract_type);
            $pricing_parameters->{slope_adjustment} = _get_slope_parameters($theo_param->{slope_adjustment}{parameters}, $display_contract_type);
        }
    } else {
        my $call_prob = $debug_information->{CALL}{base_probability};
        my $put_prob  = $debug_information->{PUT}{base_probability};

        if ($contract_type eq 'EXPIRYRANGE') {
            $pricing_parameters->{theoretical_probability} = {
                discounted_probabality   => $contract->discounted_probability->amount,
                call_and_put_probability => $call_prob->{amount} + $put_prob->{amount}};
        } else {
            $pricing_parameters->{theoretical_probability} = {call_and_put_probability => $call_prob->{amount} + $put_prob->{amount}};
        }

        $pricing_parameters->{call_bs_probability} =
            _get_bs_probability_parameters($call_prob->{parameters}{bs_probability}{parameters}, $contract->payout, 'call');
        my $call_slope_param = $call_prob->{parameters}{slope_adjustment}{parameters};
        $pricing_parameters->{call_slope_adjustment} = _get_slope_parameters($call_slope_param, 'call');
        $pricing_parameters->{put_bs_probability} =
            _get_bs_probability_parameters($put_prob->{parameters}{bs_probability}{parameters}, $contract->payout, 'put');
        my $put_slope_param = $put_prob->{parameters}{slope_adjustment}{parameters};
        $pricing_parameters->{put_slope_adjustment} = _get_slope_parameters($put_slope_param, 'put');
    }

    $pricing_parameters->{risk_markup} = $debug_information->{risk_markup}{parameters};

    $pricing_parameters->{commission_markup} = {
        base_commission       => $contract->base_commission,
        commission_multiplier => $contract->commission_multiplier($contract->payout),
    };

    return $pricing_parameters;
}

sub _get_slope_parameters {
    my $slope_param   = shift;
    my $contract_type = shift;

    my $slope_parameter = {
        $contract_type . "_weight" => $contract_type eq 'call' ? -1 : 1,
        $contract_type . "_slope" => $slope_param->{slope},
        $contract_type . "_vanilla_vega" => $slope_param->{vanilla_vega}{amount},

    };
    return $slope_parameter;
}

sub _get_bs_probability_parameters {
    my $prob            = shift;
    my $contract_payout = shift;
    my $contract_type   = shift;

    my $bs_parameter = {
        $contract_type . "_K"      => $prob->{strikes}[0],
        $contract_type . "_S"      => $prob->{spot},
        $contract_type . "_t"      => $prob->{_timeinyears},
        $contract_type . "_payout" => $contract_payout,
        map { $contract_type . '_' . $_ => $prob->{$_} } qw(discount_rate mu vol),
    };
    return $bs_parameter;
}

sub _get_market_supplement_parameters {
    my $pe = shift;

    my $ms_parameter;
    foreach $type ('vanna', 'volga', 'vega') {
        my $correction    = $type . '_correction';
        my $ms_correction = $pe->$correction;
        $ms_parameter->{$type . "_correction"}      = $ms_correction->amount;
        $ms_parameter->{$type . "_survival_weight"} = $ms_correction->peek_amount('survival_weight');
        $ms_parameter->{"Bet_" . $type}             = $ms_correction->peek_amount('bet_' . $type);
        $ms_parameter->{$type . "_market_price"}    = $ms_correction->peek_amount($type . '_market_price');

    }
    return $ms_parameter;
}

BOM::Backoffice::Request::template->process(
    'backoffice/contract_details.html.tt',
    {
        broker             => $broker,
        id                 => $id,
        short_code         => $short_code,
        currency           => $currency,
        contract_details   => {@contract_details},
        start              => $start ? $start->datetime : '',
        pricing_parameters => $pricing_parameters,
    }) || die BOM::Backoffice::Request::template->error;
code_exit_BO();


package BOM::Pricing::JapanContractDetails;

=head1 DESCRIPTION

This package is to output contract's pricing parameters that will be used by Japan team to replicate the contract price with the excel template. The format is as per required by the regulator. Please do not change it without confirmation from Quants and Japan team

=cut

use strict;
use warnings;

use Path::Tiny;
use Excel::Writer::XLSX;
use LandingCompany::Registry;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Product::Pricing::Engine::Intraday::Forex;
use BOM::Platform::Runtime;
use BOM::Platform::Chronicle;

sub parse_file {
    my ($file, $landing_company) = @_;

    my @lines = Path::Tiny::path($file)->lines;

    my $pricing_parameters;
    foreach my $line (@lines) {
        chomp $line;
        # Might have a trailing blank at the end, and any in the middle of the file are generally harmless too
        next unless length $line;
        my ($shortcode, $ask_price, $bid_price, $extra) = extract_from_code($line);

        my $currency = $landing_company =~ /japan/ ? 'JPY' : 'USD';
        my $parameters = verify_with_shortcode({
            shortcode       => $shortcode,
            currency        => $currency,
            landing_company => $landing_company,
            ask_price       => $ask_price,
            bid_price       => $bid_price,
            action_type     => 'buy',
            extra           => $extra,
        });

        $pricing_parameters->{$shortcode} = include_contract_details(
            $parameters,
            {
                order_type  => 'buy',
                order_price => $ask_price
            });

    }
    return $pricing_parameters;
}

sub verify_with_id {
    my $args = shift;

    my $id              = $args->{transaction_id};
    my $landing_company = $args->{landing_company};
    my $details         = $args->{details};

    my $action_type     = $details->{action_type};
    my $requested_price = $details->{order_price};
    my $ask_price       = $details->{ask_price};
    my $bid_price       = $details->{bid_price};
    my $traded_price    = $action_type eq 'buy' ? $ask_price : $bid_price;
    my $slippage        = $details->{price_slippage} // 0;
    # apply slippage according to reflect the difference between traded price and recomputed price
    my $adjusted_traded_contract_price =
        ($traded_price == $requested_price) ? ($action_type eq 'buy' ? $traded_price - $slippage : $traded_price + $slippage) : $traded_price;

    my $extra;
    if ($details->{long_term_prediction}) {
        $extra = join '_', (map { $details->{$_} } qw(pricing_spot high_barrier_vol long_term_prediction));
    } elsif ($details->{low_barrier_vol}) {
        $extra = join '_', (map { $details->{$_} } qw(pricing_spot high_barrier_vol low_barrier_vol));
    } else {
        $extra = join '_', (map { $details->{$_} } qw(pricing_spot high_barrier_vol));
    }
    my $parameters = verify_with_shortcode({
        shortcode       => $details->{shortcode},
        currency        => $details->{currency_code},
        landing_company => $landing_company,
        ask_price       => $adjusted_traded_contract_price,
        ($action_type eq 'sell' ? (start => $details->{sell_time}) : ()),
        action_type => $action_type,
        extra       => $extra,
    });
    my $contract_args = {
        loginID         => $details->{loginid},
        trans_id        => $id,
        order_type      => $action_type,
        order_price     => $requested_price,
        slippage_price  => $slippage,
        trade_ask_price => $ask_price,
        trade_bid_price => $bid_price,
        ref_spot        => $details->{pricing_spot},
        ref_vol         => $details->{high_barrier_vol},
        (defined $details->{low_barrier_vol}) ? (ref_vol2 => $details->{low_barrier_vol}) : (),
    };
    $parameters = include_contract_details($parameters, $contract_args);
    return $parameters;

}

sub verify_with_shortcode {
    my $args            = shift;
    my $landing_company = $args->{landing_company};
    my $short_code      = $args->{shortcode} or die "No shortcode provided";
    my $action_type     = defined $args->{action_type} ? lc $args->{action_type} : 'buy';    # default to buy if not specified
    my $verify_ask      = $args->{ask_price};                                                # This is the price to be verify
    my $verify_bid      = $args->{bid_price} // undef;
    my $currency        = $args->{currency};
    my $extra           = $args->{extra} // undef;

    my $original_contract = produce_contract($short_code, $currency);
    my $priced_at_start = make_similar_contract(
        $original_contract,
        {
            priced_at       => 'start',
            landing_company => $landing_company
        });
    my $purchase_time = $original_contract->date_start;

    my $start = $args->{start} ? Date::Utility->new($args->{start}) : Date::Utility->new($purchase_time);

    my $pricing_args = $original_contract->build_parameters;
    my $prev_tick = $original_contract->underlying->tick_at($start->epoch - 1, {allow_inconsistent => 1})->quote;
    $pricing_args->{date_pricing}    = $start;
    $pricing_args->{landing_company} = $landing_company;

    if ($extra) {
        my @extra_args = split '_', $extra;
        $pricing_args->{pricing_spot} = $extra_args[0];
        if ($priced_at_start->priced_with_intraday_model) {
            $pricing_args->{pricing_vol}          = $extra_args[1];
            $pricing_args->{long_term_prediction} = $extra_args[2];
        } elsif ($priced_at_start->pricing_vol_for_two_barriers) {    # two barrier for slope
            $pricing_args->{pricing_vol_for_two_barriers} = {
                high_barrier_vol => $extra_args[1],
                low_barrier_vol  => $extra_args[2],
            };
        } else {
            $pricing_args->{pricing_vol} = $extra_args[1];
        }
    }

    my $contract = produce_contract($pricing_args);

    my $seasonality_prefix = 'bo_' . time . '_';

    Volatility::Seasonality::set_prefix($seasonality_prefix);
    my $EEC = Quant::Framework::EconomicEventCalendar->new({
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(1),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    });
    my $events = $EEC->get_latest_events_for_period({
            from => $contract->date_start,
            to   => $contract->date_start->plus_time_interval('6d'),
        },
        $contract->underlying->for_date
    );
    Volatility::Seasonality::generate_economic_event_seasonality({
        underlying_symbols => [$contract->underlying->symbol],
        economic_events    => $events,
        date               => $contract->date_start,
        chronicle_writer   => BOM::Platform::Chronicle::get_chronicle_writer(),
    });

    # due to complexity in $action_type, this is a hacky fix.
    my @contracts = (
        [$contract, $verify_ask],
        [$contract->opposite_contract_for_sale, ($verify_bid ? $contract->discounted_probability->amount * $contract->payout - $verify_bid : undef)]);

    my ($verified_contract, $verified_opposite) = map { $contracts[$_]->[0] } (0 .. $#contracts);
    my $traded_contract = $action_type eq 'buy' ? $verified_contract : $verified_contract->opposite_contract_for_sale;
    my $discounted_probability = $verified_contract->discounted_probability;

    my $pricing_parameters = get_pricing_parameter({
        traded_contract        => $traded_contract,
        action_type            => $action_type,
        discounted_probability => $discounted_probability
    });

    my $opposite_parameters = get_pricing_parameter({
        traded_contract => $action_type eq 'buy' ? $verified_opposite : $verified_contract,
        action_type => $action_type,
        discounted_probability => $discounted_probability
    });
    foreach my $key (keys %{$opposite_parameters}) {
        foreach my $sub_key (keys %{$opposite_parameters->{$key}}) {
            my $new_sub_key = 'opposite_contract_' . $sub_key;
            $pricing_parameters->{opposite_contract}->{$new_sub_key} = $opposite_parameters->{$key}->{$sub_key};

        }
    }

    $pricing_parameters->{contract_details} = {
        short_code             => $short_code,
        description            => $original_contract->longcode,
        ccy                    => $original_contract->currency,
        payout                 => $original_contract->payout,
        trade_time             => $start->datetime,
        tick_before_trade_time => $prev_tick,
    };

    return $pricing_parameters;
}

sub get_pricing_parameter {
    my $args                   = shift;
    my $traded_contract        = $args->{traded_contract};
    my $action_type            = $args->{action_type};
    my $discounted_probability = $args->{discounted_probability};

    my $pricing_parameters =
        $traded_contract->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Forex'
        ? _get_pricing_parameter_from_IH_pricer($traded_contract, $action_type, $discounted_probability)
        : $traded_contract->pricing_engine_name eq 'Pricing::Engine::EuropeanDigitalSlope'
        ? _get_pricing_parameter_from_slope_pricer($traded_contract, $action_type, $discounted_probability)
        : $traded_contract->pricing_engine_name eq 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated'
        ? _get_pricing_parameter_from_vv_pricer($traded_contract, $action_type, $discounted_probability)
        : die "Can not obtain pricing parameter for this contract with pricing engine: $traded_contract->pricing_engine_name \n";

    return $pricing_parameters;

}

sub include_contract_details {
    my $params = shift;
    my $args   = shift;
    my @required_contract_details =
        qw(loginID trans_id order_type order_price slippage_price trade_ask_price trade_bid_price ref_spot ref_vol ref_vol2);

    foreach my $key (@required_contract_details) {
        $params->{contract_details}->{$key} = $args->{$key} // 'NA';

    }
    return $params;
}

sub _get_pricing_parameter_from_IH_pricer {
    my ($contract, $action_type, $discounted_probability) = @_;
    my $pricing_parameters;

    my $pe                = $contract->pricing_engine;
    my $bs_probability    = $pe->base_probability->base_amount;
    my $commission_markup = $contract->commission_markup->amount;

    if ($action_type eq 'sell') {
        $pricing_parameters->{bid_probability} = {
            discounted_probability => $discounted_probability->amount,
            bs_probability         => $bs_probability,
            commission_markup      => $commission_markup,
            risk_markup            => $pe->risk_markup->amount,
            map { $_ => $pe->base_probability->peek_amount($_) } qw(intraday_delta_correction intraday_vega_correction),
        };

    } else {
        $pricing_parameters->{ask_probability} = {
            bs_probability    => $bs_probability,
            commission_markup => $commission_markup,
            risk_markup       => $pe->risk_markup->amount,
            map { $_ => $pe->base_probability->peek_amount($_) } qw(intraday_delta_correction intraday_vega_correction),
        };
    }
    my @bs_keys      = ('S', 'K', 't', 'discount_rate', 'mu', 'vol');
    my $pricing_args = $pe->bet->_pricing_args;
    my @formula_args = ($pricing_args->{spot}, $pricing_args->{barrier1}, $pricing_args->{t}, 0, 0, $pricing_args->{iv});
    $pricing_parameters->{bs_probability} = {
        payout => $contract->payout,
        map { $bs_keys[$_] => $formula_args[$_] } 0 .. $#bs_keys
    };

    $pricing_parameters->{intraday_vega_correction} = {
        historical_vol_mean_reversion => BOM::Platform::Config::quants->{commission}->{intraday}->{historical_vol_meanrev},
        long_term_prediction          => $pe->long_term_prediction->amount,
        intraday_vega                 => $pe->base_probability->peek_amount('intraday_vega'),
    };

    my $intraday_delta_correction = $pe->base_probability->peek_amount('intraday_delta_correction');
    $pricing_parameters->{intraday_delta_correction} = {
          short_term_delta_correction => $contract->get_time_to_expiry->minutes < 10 ? $intraday_delta_correction
        : $contract->get_time_to_expiry->minutes > 20 ? 0
        : $pe->base_probability->peek_amount('delta_correction_short_term_value'),
        long_term_delta_correction => $contract->get_time_to_expiry->minutes > 20 ? $intraday_delta_correction
        : $contract->get_time_to_expiry->minutes < 10 ? 0
        :                                               $pe->base_probability->peek_amount('delta_correction_long_term_value'),
    };

    $pricing_parameters->{commission_markup} = {
        base_commission       => $contract->base_commission,
        commission_multiplier => $contract->commission_multiplier($contract->payout),
    };

    my $risk_markup = $pe->risk_markup;
    $pricing_parameters->{risk_markup} = {
        map { $_ => $risk_markup->peek_amount($_) // 0 }
            qw(economic_events_markup event_markup economic_events_spot_risk_markup intraday_historical_iv_risk quiet_period_markup vol_spread_markup intraday_eod_markup short_term_kurtosis_risk_markup historical_vol_markup),

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
            discounted_probability  => $discounted_probability->amount,
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
    my $pricing_arg = $contract->_pricing_args;
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

    my $risk_markup_obj = $pe->risk_markup;
    $pricing_parameters->{risk_markup} = {
        map { $_ => $risk_markup_obj->peek_amount($_) // 0 }
            qw(vol_spread_markup vol_spread bet_vega spot_spread_markup bet_delta spot_spread butterfly_greater_than_cutoff spread_to_markup),

    };

    return $pricing_parameters;
}

sub _get_pricing_parameter_from_slope_pricer {
    my ($contract, $action_type, $discounted_probability) = @_;

    #force createion of debug_information
    $contract->ask_probability;    # invoked for the side-effect
    my $debug_information = $contract->debug_information;
    my $pricing_parameters;
    my $contract_type     = $contract->pricing_code;
    my $risk_markup       = $contract->risk_markup->amount;
    my $commission_markup = $contract->commission_markup->amount;
    my $base_probability  = $debug_information->{$contract_type}{base_probability}{amount};
    $contract->ask_price;          # invoked for the side-effect

    if ($action_type eq 'sell') {
        $pricing_parameters->{bid_probability} = {
            discounted_probability  => $discounted_probability->amount,
            theoretical_probability => $base_probability,
            risk_markup             => $risk_markup,
            commission_markup       => $commission_markup,

        };

    } else {

        $pricing_parameters->{ask_probability} = {
            theoretical_probability => $base_probability,
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
    foreach my $type ('vanna', 'volga', 'vega') {
        my $correction    = $type . '_correction';
        my $ms_correction = $pe->$correction;
        $ms_parameter->{$type . "_correction"}      = $ms_correction->amount;
        $ms_parameter->{$type . "_survival_weight"} = $ms_correction->peek_amount('survival_weight');
        $ms_parameter->{"Bet_" . $type}             = $ms_correction->peek_amount('bet_' . $type);
        $ms_parameter->{$type . "_market_price"}    = $ms_correction->peek_amount($type . '_market_price');

    }
    return $ms_parameter;
}

sub extract_from_code {
    my $code = shift;

    my @fields    = split ",", $code;
    my $shortcode = $fields[0];
    my $ask_price = $fields[2];
    my $bid_price = $fields[3];
    my $extra     = $fields[5];

    return ($shortcode, $ask_price, $bid_price, $extra);
}
1;


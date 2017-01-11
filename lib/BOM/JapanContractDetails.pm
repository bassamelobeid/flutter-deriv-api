package BOM::JapanContractDetails;

=head1 DESCRIPTION

This package is to output contract's pricing parameters that will be used by Japan team to replicate the contract price with the excel template. The format is as per required by the regulator. Please do not change it without confirmation from Quants and Japan team

=cut

use lib qw(/home/git/regentmarkets/bom-backoffice);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel);
use BOM::Product::Pricing::Engine::Intraday::Forex;
use BOM::Database::ClientDB;
use Client::Account;
use BOM::Database::DataMapper::Transaction;
use BOM::Backoffice::Sysinit ();
use LandingCompany::Registry;
use Path::Tiny;
use Spreadsheet::WriteExcel;

sub parse_file {
    my ($file, $landing_company) = @_;

    my @lines = Path::Tiny::path($file)->lines;

    my $pricing_parameters;
    foreach my $line (@lines) {
        chomp $line;
        my @fields    = split ",", $line;
        my $shortcode = $fields[0];
        my $ask_price = $fields[2];

        my $currency = $landing_company =~ /japan/ ? 'JPY' : 'USD';
        my $parameters = verify_with_shortcode({
            broker                    => $broker,
            shortcode                 => $shortcode,
            currency                  => $currency,
            landing_company           => $landing_company,
            contract_price            => $ask_price,
            action_type               => 'buy',
            include_opposite_contract => 1,
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
    my $broker          = $args->{broker};
    my $details         = BOM::Database::DataMapper::Transaction->new({
            broker_code => $broker,
            operation   => 'backoffice_replica',
        })->get_details_by_transaction_ref($id);

    my $client          = Client::Account::get_instance({'loginid' => $details->{loginid}});
    my $action_type     = $details->{action_type};
    my $requested_price = $details->{order_price};
    my $trade_price     = $action_type eq 'buy' ? $details->{ask_price} : $details->{bid_price};

    # apply slippage according to reflect the difference between traded price and recomputed price
    my $adjusted_traded_contract_price =
        ($traded_price == $requested_price) ? ($action_type eq 'buy' ? $traded_price - $slippage : $traded_price + $slippage) : $traded_price;

    my $parameters = verify_with_shortcode({
        broker          => $broker,
        shortcode       => $details->{shortcode},
        currency        => $details->{currency_code},
        landing_company => $landing_company,
        contract_price  => $adjusted_traded_contract_price,
        start           => $action_type eq 'buy' ? $details->{purchase_time} : $details->{sell_time},
        action_type     => $action_type,
    });

    my $args = (
        loginID         => $details->{loginid},
        trans_id        => $id,
        order_type      => $action_type,
        order_price     => $requested_price,
        slippage_price  => $details->{price_slippage},
        trade_ask_price => $details->{ask_price},
        trade_bid_price => $details->{bid_price},
        ref_spot        => $details->{pricing_spot},
        ref_vol         => $details->{high_barrier_vol},
        ref_vol2        => $details->{low_barrier_vol} // 'NA',
    );

    $parameters = include_contract_details($parameters, $args);

    return $parameters;

}

sub verify_with_shortcode {
    my $args = shift;

    my $landing_company           = $args->{landing_company};
    my $short_code                = $args->{shortcode};
    my $action_type               = $args->{action_type};
    my $verify_price              = $args->{contract_price};              # This is the price to be verify
    my $include_opposite_contract = $args->{include_opposite_contract};
    my $currency                  = $args->{currency};

    my $original_contract = produce_contract($short_code, $currency);
    my $purchase_time = $original_contract->date_start;

    my $start = $args->{start_time} ? Date::Utility->new($args->{start_time}) : Date::Utility->new($purchase_time);

    my $pricing_args = $original_contract->build_parameters;
    $pricing_args->{date_pricing}    = $start;
    $pricing_args->{landing_company} = $landing_company;

    my $contract       = produce_contract($pricing_args);
    my $contract_price = $action_type eq 'buy' ? $contract->ask_price : $contract->bid_price;
    my $prev_tick      = $contract->underlying->tick_at($start->epoch - 1, {allow_inconsistent => 1})->quote;

    my $diff = $verify_price - $contract_price;
    # If there is difference, look backward and forward to find the match price.
    if ($diff) {
        my $new_contract;
        LOOP:
        for my $lookback (1 .. 60, map -$_, 1 .. 60) {
            $pricing_args->{date_pricing} = Date::Utility->new($contract->date_start->epoch - $lookback);
            $pricing_args->{date_start}   = Date::Utility->new($contract->date_start->epoch - $lookback);
            $new_contract                 = produce_contract($pricing_args);
            my $new_price = $action_type eq 'buy' ? $new_contract->ask_price : $new_contract->bid_price;
            last LOOP if (abs($new_price - $verify_price) / $new_contract->payout <= 0.001);
        }
        $contract = $new_contract;
    }

    my $traded_contract = $action_type eq 'buy' ? $contract : $contract->opposite_contract;
    my $discounted_probability = $contract->discounted_probability;

    my $pricing_parameters = get_pricing_parameter({
        traded_contract        => $traded_contract,
        action_type            => $action_type,
        discounted_probability => $discounted_probability
    });
    if ($include_opposite_contract == 1) {

        my $opposite_contract = get_pricing_parameter({
            traded_contract        => $contract->opposite_contract,
            action_type            => $action_type,
            discounted_probability => $discounted_probability
        });
        my $new_naming;
        foreach my $key (keys %{$opposite_contract}) {
            foreach my $sub_key (keys %{$opposite_contract->{$key}}) {
                my $new_sub_key = 'opposite_contract_' . $sub_key;
                $pricing_parameters->{opposite_contract}->{$new_sub_key} = $opposite_contract->{$key}->{$sub_key};

            }
        }

    }

    $pricing_parameters->{contract_details} = {
        short_code             => $short_code,
        description            => $original_contract->longcode,
        ccy                    => $contract->currency,
        payout                 => $contract->payout,
        trade_time             => $start_time,
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
        : die "Can not obtain pricing parameter for this contract with pricing engine: $contract->pricing_engine_name \n";

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
            qw(economic_events_markup intraday_historical_iv_risk quiet_period_markup vol_spread_markup intraday_eod_markup short_term_kurtosis_risk_markup),

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
            qw(vol_spread_markup vol_spread bet_vega spot_spread_markup bet_delta spot_spread butterfly_markup butterfly_greater_than_cutoff spread_to_markup),

    };

    return $pricing_parameters;
}

sub _get_pricing_parameter_from_slope_pricer {
    my ($contract, $action_type, $discounted_probability) = @_;

    #force createion of debug_information
    my $ask_probability   = $contract->ask_probability;
    my $debug_information = $contract->debug_information;
    my $pricing_parameters;
    my $contract_type     = $contract->pricing_code;
    my $risk_markup       = $contract->risk_markup->amount;
    my $commission_markup = $contract->commission_markup->amount;
    my $base_probability  = $debug_information->{$contract_type}{base_probability}{amount};
    my $ask_price         = $contract->ask_price;

    if ($action_type eq 'sell') {
        $pricing_parameters->{bid_probability} = {
            discounted_probability            => $discounted_probability->amount,
            opposite_contract_ask_probability => $contract->ask_probability->amount
        };

        $pricing_parameters->{opposite_contract_ask_probability} = {
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

sub generate_form {

    my $args = shift;

    my $form;

    BOM::Backoffice::Request::template->process(
        'backoffice/japan_contract_details.html.tt',
        {
            broker     => $args->{broker},
            upload_url => $args->{upload_url},
        }) || die BOM::Backoffice::Request::template->error;

    return $form;

}

sub output_on_display {
    my $contract_params = shift;

    BOM::Backoffice::Request::template->process(
        'backoffice/contract_details.html.tt',
        {
            pricing_parameters => $contract_params,
        }) || die BOM::Backoffice::Request::template->error;

}

sub batch_output_as_excel {
    my $contract  = shift;
    my $file_name = shift;
    my $workbook  = Spreadsheet::WriteExcel->new($file_name);
    my $worksheet = $workbook->add_worksheet();
    my @combined;
    foreach my $c (keys %{$contract}) {
        my (@keys, @value);
        foreach my $key (sort values %{$contract->{$c}}) {
            push @keys,  keys %{$key};
            push @value, values %{$key};
        }

        push @combined, \@keys;
        push @combined, \@value;
    }

    $worksheet->write_row('A1', \@combined);
    $workbook->close;

    return $workbook;
}

sub single_output_as_excel {
    my $contract  = shift;
    my $file_name = shift;
    my $workbook  = Spreadsheet::WriteExcel->new($file_name);
    my $worksheet = $workbook->add_worksheet();
    my (@keys, @value);

    foreach my $key (keys %{$contract}) {
        push @keys,  $key;
        push @value, $contract->{$key};
    }

    my @combined = (\@keys, \@value);

    $worksheet->write_row('A1', \@combined);
    $workbook->close;

    return $workbook;
}

1;


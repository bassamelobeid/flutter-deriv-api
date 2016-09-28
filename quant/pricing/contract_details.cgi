#!/etc/rmg/bin/perl

=head1 NAME

Contract's pricing details

=head1 DESCRIPTION

A b/o tool that output contract's pricing parameters that will be used to replicate the contract price with an excel template.
This is a Japanese regulatory requirements.

=cut

package main;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::Pricing::Engine::Intraday::Forex;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel);
use BOM::Backoffice::Sysinit ();
use Price::RoundPrecision::JPY;
use Format::Util::Numbers qw(roundnear);
BOM::Backoffice::Sysinit::init();
BOM::Backoffice::Auth0::can_access(['Quants']);
my %params = %{request()->params};
my ($pricing_parameters, @contract_details, $start);

my $broker = $params{broker} // request()->broker_code;
my $id = $params{id} ? $params{id} : '';
my $JPY_precision = Price::RoundPrecision::JPY->precision;

if ($broker and $id) {
    my $details = BOM::Database::DataMapper::Transaction->new({
            broker_code => $broker,
            operation   => 'backoffice_replica',
        })->get_details_by_transaction_ref($id);

    my $original_contract = produce_contract($details->{shortcode}, $details->{currency_code});

    $start = $params{start} ? Date::Utility->new($params{start}) : $original_contract->date_start;
    my $pricing_args = $original_contract->build_parameters;
    $pricing_args->{date_pricing} = $start;
    my $contract       = produce_contract($pricing_args);
    my $traded_bid     = $details->{bid_price};
    my $traded_ask     = $details->{ask_price};
    my $slippage_price = $details->{price_slippage};
    my $action_type    = $details->{action_type};

    $pricing_parameters =
          $contract->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Forex' ? _get_pricing_parameter_from_IH_pricer($contract)
        : $contract->pricing_engine_name eq 'Pricing::Engine::EuropeanDigitalSlope'          ? _get_pricing_parameter_from_slope_pricer($contract)
        :   die "Can not obtain pricing parameter for this contract with pricing engine: $contract->pricing_engine_name \n";

    @contract_details = (
        login_id       => $details->{loginid},
        slippage_price => $slippage_price ? roundnear($JPY_precision, $slippage_price) : 'NA.',
        order_type => $action_type,
        order_price => ($action_type eq 'buy') ? $traded_ask : $traded_bid,
        trans_id    => $id,
        short_code  => $contract->shortcode,
        payout      => $contract->payout,
        description => $contract->longcode,
        ccy         => $details->{currency_code},
        trade_ask_price => $traded_ask,
        trade_bid_price => $traded_bid // 'NA. (unsold)',
    );
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
    my $contract = shift;
    my $pricing_parameters;
    my $pe                = $contract->pricing_engine;
    my $bs_probability    = $pe->formula->($pe->_formula_args);
    my $commission_markup = $contract->commission_markup->amount;

    $pricing_parameters->{ask_probability} = {
        bs_probability    => $bs_probability,
        commission_markup => $commission_markup,
        map { $_ => $pe->$_->amount } qw(intraday_delta_correction intraday_vega_correction risk_markup),
    };

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
        intraday_historical_iv_risk => $risk_markup->peek_amount('intraday_historical_iv_risk') // 0,
        quiet_period_markup         => $risk_markup->peek_amount('quiet_period_markup')         // 0,
        eod_market_risk_markup      => $pe->eod_market_risk_markup->amount                      // 0,
        economic_events_markup      => $pe->economic_events_markup->amount,
    };

    return $pricing_parameters;

}

sub _get_pricing_parameter_from_slope_pricer {
    my $contract          = shift;
    my $ask_probability   = $contract->ask_probability;
    my $pe                = $contract->pricing_engine;
    my $debug_information = $pe->debug_information;
    my $pricing_parameters;
    my $contract_type     = $pe->contract_type;
    my $risk_markup       = $contract->risk_markup->amount;
    my $commission_markup = $contract->commission_markup->amount;

    $pricing_parameters->{ask_probability} = {
        theoretical_probability => $pe->base_probability,
        risk_markup             => $risk_markup,
        commission_markup       => $commission_markup,
    };

    my $theo_param = $debug_information->{$contract_type}{base_probability}{parameters};

    if ($contract->priced_with ne 'base') {
        $pricing_parameters->{bs_probability}   = _get_bs_probability_parameters($theo_param->{bs_probability}{parameters});
        $pricing_parameters->{slope_adjustment} = {
            weight => $contract_type eq 'CALL' ? -1 : 1,
            slope => $theo_param->{slope_adjustment}{parameters}{slope},
            vanilla_vega => $theo_param->{slope_adjustment}{parameters}{vanilla_vega}{amount},
        };
    } else {
        $pricing_parameters->{bs_probability} =
            _get_bs_probability_parameters($theo_param->{numeraire_probability}{parameters}{bs_probability}{parameters});
        my $slope_param = $theo_param->{numeraire_probability}{parameters}{slope_adjustment}{parameters};
        $pricing_parameters->{slope_adjustment} = {
            weight => $contract_type eq 'CALL' ? -1 : 1,
            slope => $slope_param->{slope},
            vanilla_vega => $slope_param->{vanilla_vega}{amount},
        };

    }
    $pricing_parameters->{bs_probability}->{payout} = $contract->payout;
    $pricing_parameters->{risk_markup} = $debug_information->{risk_markup}{parameters};

    $pricing_parameters->{commission_markup} = {
        base_commission       => $contract->base_commission,
        commission_multiplier => $contract->commission_multiplier($contract->payout),
    };

    return $pricing_parameters;
}

sub _get_bs_probability_parameters {
    my $prob         = shift;
    my $bs_parameter = {
        'K' => $prob->{strikes}[0],
        "S" => $prob->{spot},
        't' => $prob->{_timeinyears},
        map { $_ => $prob->{$_} } qw(discount_rate mu vol),
    };
    return $bs_parameter;
}
BOM::Platform::Context::template->process(
    'backoffice/contract_details.html.tt',
    {
        broker             => $broker,
        id                 => $id,
        contract_details   => {@contract_details},
        start              => $start ? $start->datetime : '',
        pricing_parameters => $pricing_parameters,
    }) || die BOM::Platform::Context::template->error;
code_exit_BO();


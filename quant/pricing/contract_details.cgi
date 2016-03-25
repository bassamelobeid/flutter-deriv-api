#!/usr/bin/perl

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
use BOM::Platform::Plack qw( PrintContentType PrintContentType_excel);
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();
BOM::Backoffice::Auth0::can_access(['Quants']);
my %params = %{request()->params};
my ($pricing_parameters, @contract_details, $start);

my $broker = request()->broker->code;
my $id = $params{id} ? $params{id} : '';

if ($broker and $id) {
    my $db = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db;

    my $details = BOM::Database::DataMapper::Transaction->new({
            db => $db,
        })->get_details_by_transaction_ref($id);

    my $original_contract = produce_contract($details->{shortcode}, $details->{currency_code});

    $start = $params{start} ? Date::Utility->new($params{start}) : $original_contract->date_start;
    my $pricing_args = $original_contract->build_parameters;
    $pricing_args->{date_pricing} = $start;
    my $contract = produce_contract($pricing_args);

    $pricing_parameters =
          $contract->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Forex' ? _get_pricing_parameter_from_IH_pricer($contract)
        : $contract->pricing_engine_name eq 'Pricing::Engine::EuropeanDigitalSlope'          ? _get_pricing_parameter_from_slope_pricer($contract)
        :   die "Can not obtain pricing parameter for this contract with pricing engine: $contract->pricing_engine_name \n";

    @contract_details = (
        login_id    => $details->{loginid},
        trans_id    => $id,
        short_code  => $contract->shortcode,
        description => $contract->longcode,
        ccy         => $details->{currency_code},
        ask_price   => $contract->ask_price,
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
    my $pe = BOM::Product::Pricing::Engine::Intraday::Forex->new({bet => $contract});
    my $ask_probability = $contract->ask_probability;
    $pricing_parameters->{ask_probability} = {
        bs_probability => $ask_probability->peek_amount(lc($contract->code) . '_theoretical_probability'),
        map { $_ => $ask_probability->peek_amount($_) } qw(intraday_delta_correction vega_correction risk_markup commission_markup),
    };

    my @bs_keys = ('S', 'K', 't', 'discount_rate', 'mu', 'vol');
    my @formula_args = $contract->pricing_engine->_formula_args;
    $pricing_parameters->{bs_probability} = {
        payout => $contract->payout,
        map { $bs_keys[$_] => $formula_args[$_] } 0 .. $#bs_keys
    };

    $pricing_parameters->{vega_correction} = {
        historical_vol_mean_reversion => BOM::Platform::Static::Config::quants->{commission}->{intraday}->{historical_vol_meanrev},
        map { $_ => $ask_probability->peek_amount($_) } qw(intraday_vega long_term_prediction),
    };

    $pricing_parameters->{intraday_delta_correction} = {
          short_term_delta_correction => $contract->get_time_to_expiry->minutes < 10 ? $pe->_get_short_term_delta_correction
        : $contract->get_time_to_expiry->minutes > 20 ? 0
        : $ask_probability->peek_amount('delta_correction_short_term_value'),
        long_term_delta_correction => $contract->get_time_to_expiry->minutes > 20 ? $pe->_get_long_term_delta_correction
        : $contract->get_time_to_expiry->minutes < 10 ? 0
        :                                               $ask_probability->peek_amount('delta_correction_long_term_value'),
    };

    $pricing_parameters->{risk_markup} = {
        intraday_historical_iv_risk => $contract->is_atm_bet ? 0 : $ask_probability->peek_amount('intraday_historical_iv_risk'),
        map { $_ => $ask_probability->peek_amount($_) } qw(economic_events_markup eod_market_risk_markup),
    };

    $pricing_parameters->{commission_markup} = {
        base_commission         => $ask_probability->peek_amount('intraday_historical_fixed'),
        quite_period_adjustment => $ask_probability->peek_amount('quiet_period_markup') ? $ask_probability->peek_amount('quiet_period_markup') : 0,
        map { $_ => $ask_probability->peek_amount($_) } qw(digital_spread_percentage dsp_scaling),
    };

    return $pricing_parameters;

}

sub _get_pricing_parameter_from_slope_pricer {
    my $contract          = shift;
    my $ask_probability   = $contract->ask_probability;
    my $debug_information = $contract->pricing_engine->debug_information;
    my $pricing_parameters;
    my $contract_type = $contract->pricing_engine->contract_type;
    $pricing_parameters->{ask_probability} = {
        theoretical_probability => $ask_probability->peek_amount('theo_probability'),
        map { $_ => $ask_probability->peek_amount($_) } qw(risk_markup commission_markup),
    };

    $pricing_parameters->{commission_markup} = {digital_spread_percentage => 0.035};

    my $theo_param = $debug_information->{$contract_type}{theo_probability}{parameters};

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


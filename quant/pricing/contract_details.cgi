#!/usr/bin/perl

=head1 NAME

Contract's pricing details

=head1 DESCRIPTION

A b/o tool that output contract's pricing details.

=cut

package main;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;

use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Product::Pricing::Engine::Intraday::Forex;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();
PrintContentType();
riginal_contract->date_start
BrokerPresentation("Contract's details");
BOM::Backoffice::Auth0::can_access(['Quants']);

Bar("Contract's Parameters");
my $original_contract =
    (request()->param('shortcode') and request()->param('currency'))
    ? produce_contract(request()->param('shortcode'), request()->param('currency'))
    : '';
}

my $date_start = (request()->param('start')) ? Date::Utility->new(request()->param('start')) : $original_contract->date_start;
my $contract = make_similar_contract($original_contract, {priced_at => $date_start});


my $pricing_parameters = $contract->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Forex' ? _get_pricing_parameter_from_IH_pricer($contract) : $contract->pricing_engine_name eq 'Pricing::Engine::EuropeanDigitalSlope' ? _get_pricing_parameter_from_slope_pricer($contract ) : die "Can not obtain pricing parameter for this contract with pricing engine: $contract->pricing_engine_name \n";


sub _get_pricing_parameter_from_IH_pricer {
   my $contract = shift;
   my $pricing_parameters;
   my $pricing_engine_obj = BOM::Product::Pricing::Engine::Intraday::Forex->new({bet=>$contract});
   my $ask_probability = $contract->ask_probability;

  $pricing_parameters->{probability} = {
     black_scholes_probability => $ask_probability->peek_amount(lc($contract->code) . '_theoretical_probability');
     delta_correction          => $ask_probability->peek_amount('intraday_delta_correction');
     vega_correction           => $ask_probability->peek_amount('intraday_vega_correction');
     risk_markup               => $ask_probability->peek_amount('risk_markup');
     commission_markup         => $ask_probability->peek_amount('commission_markup');
  };

  $pricing_paramters->{vega_correction} = {
     historical_vol_mean_reversion => BOM::Platform::Static::Config::quants->{commission}->{intraday}->{historical_vol_meanrev};
     intraday_vega => $ask_probability->peek_amount('intraday_vega');
     long_term_vol_prediction => $ask_probability->peek_amount('long_term_prediction');
  };

 $pricing_paramters->{delta_correction} = {
    short_term_delta_correction => $contract->get_time_to_expiry->minutes  < 10 ? $pricing_engine_obj->_get_short_term_delta_correction : $contract->get_time_to_expiry->minutes > 20 ? 0 : $ask_probability->peek_amount('delta_correction_short_term_value')  ;
    long_term_delta_correction => $contract->get_time_to_expiry->minutes  > 20 ? $pricing_engine_obj->_get_long_term_delta_correction : $contract->get_time_to_expiry->minutes < 10 ? 0 : $ask_probability->peek_amount('delta_correction_long_term_value')  ; 
 };

 $pricing_parameters->{risk_markup} = {
    eoconomic_events_markup => $ask_probability->peek_amount('economic_events_markup');
    eod_market_risk_markup  => $ask_probobality->peek_amount('eod_market_risk_markup');
    intraday_historical_iv_risk => not $contract->is_atm_bet ? $ask_probability->peek_amount('intraday_historical_iv_risk') : 0;
 };

 $pricing_paramters->{economic_events_markup} = {
   economic_events_volatility_risk_markup => $ask_probobality->peek_amount('economic_events_volatility_risk_markup');
   economic_events_spot_risk_markup => $ask_probobality->peek_amount('economic_events_spot_risk_markup');
 };

 $pricing_paramters->{economic_events_volatility_risk_markup} = {
   theoretical_price_with_vol_adjusted_for_news => 

 };


 
}




#x BOM::Platform::Context::template->process(
#    'backoffice/contract_details.html.tt',
#    {
#        contract        => $contract,
#    }) || die BOM::Platform::Context::template->error;

code_exit_BO();

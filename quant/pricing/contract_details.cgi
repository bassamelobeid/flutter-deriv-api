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
use Pricing::Engine::EuropeanDigitalSlope;
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
   my $pe = BOM::Product::Pricing::Engine::Intraday::Forex->new({bet=>$contract});
   my $ask_probability = $contract->ask_probability;

  $pricing_parameters->{probability} = {
     bs_probability => $ask_probability->peek_amount(lc($contract->code) . '_theoretical_probability');
     delta_correction          => $ask_probability->peek_amount('intraday_delta_correction');
     vega_correction           => $ask_probability->peek_amount('intraday_vega_correction');
     risk_markup               => $ask_probability->peek_amount('risk_markup');
     commission_markup         => $ask_probability->peek_amount('commission_markup');
  };

  my @bs_keys =  = ('S', 'K', 't', 'r_q','mu','vol') ;
  my @formula_args = $contract->pricing_engine->_formula_args ;  
  $pricing_parameters->{bs_probability} = map { $bs_keys[$_] => $formula_args[$_] }0..$#bs_keys ;

  $pricing_parameters->{vega_correction} = {
     historical_vol_mean_reversion => BOM::Platform::Static::Config::quants->{commission}->{intraday}->{historical_vol_meanrev};
     intraday_vega => $ask_probability->peek_amount('intraday_vega');
     long_term_vol_prediction => $ask_probability->peek_amount('long_term_prediction');
  };

 $pricing_parameters->{delta_correction} = {
    short_term_delta_correction => $contract->get_time_to_expiry->minutes  < 10 ? $pe->_get_short_term_delta_correction : $contract->get_time_to_expiry->minutes > 20 ? 0 : $ask_probability->peek_amount('delta_correction_short_term_value')  ;
    long_term_delta_correction => $contract->get_time_to_expiry->minutes  > 20 ? $pe->_get_long_term_delta_correction : $contract->get_time_to_expiry->minutes < 10 ? 0 : $ask_probability->peek_amount('delta_correction_long_term_value')  ; 
 };

 $pricing_parameters->{risk_markup} = {
    eoconomic_events_markup => $ask_probability->peek_amount('economic_events_markup');
    eod_market_risk_markup  => $ask_probobality->peek_amount('eod_market_risk_markup');
    intraday_historical_iv_risk => not $contract->is_atm_bet ? $ask_probability->peek_amount('intraday_historical_iv_risk') : 0;
 };

 $pricing_parameters->{economic_events_markup} = {
   economic_events_volatility_risk_markup => $ask_probobality->peek_amount('economic_events_volatility_risk_markup');
   economic_events_spot_risk_markup => $ask_probobality->peek_amount('economic_events_spot_risk_markup');
 };

 $pricing_parameters->{economic_events_volatility_risk_markup} = {
   theoretical_price_with_vol_adjusted_for_news => $pe->clone({
           pricing_vol => $pe->news_adjusted_pricing_vol,
           intraday_trend => $pe->intraday_trend,
   })->probability->amount;
  theoretical_price_with_normal_vol => $pe->probability->amount;
  volatility_adjusted_for_economic_event => $pe->news_adjusted_pricing_vol,
  normal_volatility       => $contract->pricing_vol;
  };

 return $pricing_parameters;

}


sub _get_pricing_parameter_from_slope_pricer{
  my $contract = shift;
  my $ask_probability = $contract->ask_probability;
  my $debug_information = $contract->pricing_engine->debug_information;
  my $pricing_parameters;
 
 $pricing_parameters->{probability} = {
     theo_probability => $ask_probability->peek_amount('theoretical_probability');
     risk_markup               => $ask_probability->peek_amount('risk_markup');
     commission_markup         => $ask_probability->peek_amount('commission_markup');
  };

  my $theo_param = $debug_information->{$contract->code}{theo_probability}{parameters};
  $pricing_parameters->{theo_probability} = { map {$_ => $theo_param->{$_}{amount}}keys $theo_param};
 
  my $bs_probability = $contract->priced_with ne 'base' ? $theo_param->{bs_probability}{parameters} : $theo_param->{numeraire_probability}{parameters}{bs_probability}{parameters};
  $pricing_parameters->{bs_probability} = {
    'S' => $bs_probability->{spot},
    'K' => $bs_probability->{strikes}[0],
    't' => $bs_probability->{_timeinyears},
    'r_q' => $bs_probability->{discount_rate},
    'mu'  => $bs_probability->{mu},
    'vol' => $bs_probability->{vol}, 
  };

  $pricing_parameters->{slope_adjustment} = {
    slope => $theo_param->{slope_adjustment}{parameters}{slope},
    vanilla_vega => $theo_param->{slope_adjustment}{parameters}{vanilla_vega}{amount},
  }
 
  $pricing_parameters->{risk_markup} = $debug_information->{risk_markup}{parameters};

  return $pricing_parameters;
}


 BOM::Platform::Context::template->process(
   'backoffice/contract_details.html.tt',
    {
        contract        => $contract,
        pricing_parameters => $pricing_paramters,
    }) || die BOM::Platform::Context::template->error;

code_exit_BO();

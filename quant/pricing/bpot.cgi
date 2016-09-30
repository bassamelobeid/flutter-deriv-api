#!/etc/rmg/bin/perl

=head1 NAME

Bet Price Through Time

=head1 DESCRIPTION

A b/o tool that plots a bet's price and the underlying market's spot
over the duration of the bet.

=cut

package main;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;

use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use BOM::PricingDetails;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use BOM::Platform::Client;
PrintContentType();
BrokerPresentation('Bet Price Over Time');
BOM::Backoffice::Auth0::can_access(['Quants']);

Bar("Bet Parameters");

my $bet = do {
    my $contract_object = '';
    my ($loginid, $shortcode, $currency) = map {request()->param($_)} qw(loginid shortcode currency);
    if ($loginid and $shortcode and $currency) {
        my $client = BOM::Platform::Client::get_instance({'loginid' => $loginid});
        my $contract_parameters = shortcode_to_parameters($shortcode, $currency);
        $contract_parameters->{landing_company} = $client->landing_company->short;
        $contract_object = produce_contract($contract_parameters);
    }
    $contract_object;
};

my ($start, $end, $timestep, $debug_link);
if ($bet) {
    $start =
          (request()->param('start')) ? Date::Utility->new(request()->param('start'))
        : (request()->param('purchase_time') and $bet->starts_as_forward_starting) ? Date::Utility->new(request()->param('purchase_time'))
        :                                                                            $bet->date_start;
    $end =
          (request()->param('end')) ? Date::Utility->new(request()->param('end'))
        : ($bet->tick_expiry)       ? $bet->date_start->plus_time_interval($bet->max_tick_expiry_duration)
        :                             $bet->date_expiry;
    $end = Date::Utility->new if ($end->epoch > time);
    my $duration = $end->epoch - $start->epoch;
    my $interval = ($bet->tick_expiry) ? '1s' : request()->param('timestep') || max(1, int($duration / 5));
    $timestep = Time::Duration::Concise::Localize->new(interval => $interval);

    $timestep = Time::Duration::Concise::Localize->new(interval => int($duration / 100))
        if ($duration / $timestep->seconds > 100);    # Don't let them go crazy asking for hundreds of points.

    my $start_bet = make_similar_contract($bet, {priced_at => $start});
    $debug_link = BOM::PricingDetails->new({bet => $start_bet})->debug_link;
}

BOM::Platform::Context::template->process(
    'backoffice/bpot.html.tt',
    {
        bet        => $bet,
        start      => $start ? $start->datetime : '',
        end        => $end ? $end->datetime : '',
        timestep   => $timestep ? $timestep->as_concise_string : '',
        debug_link => $debug_link,
    }) || die BOM::Platform::Context::template->error;

code_exit_BO();

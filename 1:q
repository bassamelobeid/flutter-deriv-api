#!/usr/bin/perl

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
use BOM::PricingDetails;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('Bet Price Over Time');
BOM::Backoffice::Auth0::can_access(['Quants']);

Bar("Bet Parameters");
my $bet =
    (request()->param('shortcode') and request()->param('currency'))
    ? produce_contract(request()->param('shortcode'), request()->param('currency'))
    : '';
my ($start, $end, $timestep, $graph_url, $debug_link);
if ($bet) {
    $start = (request()->param('start')) ? Date::Utility->new(request()->param('start')) : $bet->date_start;
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

    $graph_url =
          'bpot_graph.cgi?shortcode='
        . request()->param('shortcode')
        . '&currency='
        . request()->param('currency')
        . '&start='
        . $start->epoch . '&end='
        . $end->epoch
        . '&timestep='
        . $timestep->as_concise_string . '&'
        . rand(100000);

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
        graph_url  => $graph_url,
    }) || die BOM::Platform::Context::template->error;

code_exit_BO();

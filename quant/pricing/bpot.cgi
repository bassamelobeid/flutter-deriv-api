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
system_initialize();

use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Product::Helper::PricingDetails;
use BOM::Platform::Plack qw( PrintContentType );

PrintContentType();
BrokerPresentation('Bet Price Over Time');
BOM::Platform::Auth0::can_access(['Quants']);

Bar("Bet Parameters");
my $bet =
    (request()->param('shortcode') and request()->param('currency'))
    ? produce_contract(request()->param('shortcode'), request()->param('currency'))
    : '';

my $graph_url =
    (request()->param('shortcode') and request()->param('currency'))
    ? 'bpot_graph.cgi?shortcode='
    . request()->param('shortcode')
    . '&currency='
    . request()->param('currency')
    . '&start='
    . request()->param('start') . '&end='
    . request()->param('end')
    . '&timestep='
    . request()->param('timestep') . '&'
    . rand(100000)
    : '';

my $debug_link = '';

if ($bet) {
    $bet = make_similar_contract($bet, {priced_at => 'start'});
    $debug_link = BOM::Product::Helper::PricingDetails->new({bet => $bet})->debug_link;
}

BOM::Platform::Context::template->process(
    'backoffice/bpot.html.tt',
    {
        input      => request()->params,
        bet        => $bet,
        debug_link => $debug_link,
        graph_url  => $graph_url,
    }) || die BOM::Platform::Context::template->error;

code_exit_BO();

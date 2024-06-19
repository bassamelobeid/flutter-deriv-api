#!/etc/rmg/bin/perl

=head1 NAME

Bet Price Through Time

=head1 DESCRIPTION

A b/o tool that plots a bet's price and the underlying market's spot
over the duration of the bet.

=cut

package main;
use strict;
use warnings;

use Syntax::Keyword::Try;
use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;

use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use Finance::Contract::Longcode   qw( shortcode_to_parameters );
use BOM::PricingDetails;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
use JSON::MaybeUTF8               qw(:v1);
BOM::Backoffice::Sysinit::init();

use BOM::User::Client;
use LandingCompany::Registry;

PrintContentType();
BrokerPresentation('Bet Price Over Time');

Bar("Bet Parameters");

my ($loginid, $broker, $transaction_id) = map { request()->param($_) } qw(loginid broker transaction_id);

my $landing_company;
my $lc_registry;
if ($broker) {
    $lc_registry = LandingCompany::Registry->by_broker($broker);
} elsif ($loginid) {
    $lc_registry = LandingCompany::Registry->by_loginid($loginid);
}

$landing_company = $lc_registry->short if $lc_registry;
my $limit_order = request()->param('limit_order');
my ($shortcode, $currency);

my $bet = do {
    my $contract_object = '';
    ($shortcode, $currency) = map { request()->param($_) } qw(shortcode currency);

    if ($landing_company and $shortcode and $currency) {
        my $contract_parameters = shortcode_to_parameters($shortcode, $currency);
        if ($limit_order) {
            $limit_order = decode_json_utf8($limit_order);

            # because we are pricing at start we need to make a few adjustment.
            $contract_parameters->{basis_spot}  = $limit_order->{stop_out}->{basis_spot};
            $contract_parameters->{limit_order} = {
                  ($limit_order->{take_profit} and $limit_order->{take_profit}->{order_amount})
                ? (take_profit => $limit_order->{take_profit}->{order_amount})
                : (),
                ($limit_order->{stop_loss} and $limit_order->{stop_loss}->{order_amount})
                ? (stop_loss => $limit_order->{stop_loss}->{order_amount} * -1)
                : (),
            };
        }

        $contract_parameters->{landing_company} = $landing_company;
        $contract_object = produce_contract($contract_parameters);
    }
    $contract_object;
};

my ($start, $end, $timestep, $debug_link);
if ($bet) {
    $start =
          (request()->param('start'))                                              ? Date::Utility->new(request()->param('start'))
        : (request()->param('purchase_time') and $bet->starts_as_forward_starting) ? Date::Utility->new(request()->param('purchase_time'))
        : ($bet->starts_as_forward_starting)                                       ? $bet->date_start->minus_time_interval('1m')
        :                                                                            $bet->date_start;
    $end =
          (request()->param('end')) ? Date::Utility->new(request()->param('end'))
        : ($bet->tick_expiry)       ? $bet->date_start->plus_time_interval($bet->_max_tick_expiry_duration)
        :                             $bet->date_expiry;
    $end = Date::Utility->new if ($end->epoch > time);
    my $duration = $end->epoch - $start->epoch;
    my $interval = ($bet->tick_expiry) ? '1s' : request()->param('timestep') || max(1, int($duration / 5));
    $timestep = Time::Duration::Concise::Localize->new(interval => $interval);

    $timestep = Time::Duration::Concise::Localize->new(interval => int($duration / 100))
        if ($duration / $timestep->seconds > 100);    # Don't let them go crazy asking for hundreds of points.

    try {
        my $start_bet = make_similar_contract(
            $bet,
            {
                date_pricing    => $start,
                landing_company => $landing_company,
                bo_inspection   => 1
            });
        $debug_link = BOM::PricingDetails->new({
                bet            => $start_bet,
                transaction_id => $transaction_id,
                client_loginid => $loginid
            }
        )->debug_link()
            unless ($bet->category_code eq 'multiplier' && !$loginid);

    } catch ($e) {
        code_exit_BO("<pre>$e</pre>");
    }
}

BOM::Backoffice::Request::template()->process(
    'backoffice/bpot.html.tt',
    {
        longcode => $bet ? localize($bet->longcode) : '',
        bet      => $bet,
        start    => $start    ? $start->datetime             : '',
        end      => $end      ? $end->datetime               : '',
        timestep => $timestep ? $timestep->as_concise_string : '',
        defined $limit_order ? (limit_order => $limit_order) : (),
        debug_link => $debug_link,
    }) || die BOM::Backoffice::Request::template()->error;

code_exit_BO();

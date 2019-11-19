#!/etc/rmg/bin/perl

=head1 NAME

Bet Price Through Time: Graph image generation.

=head1 DESCRIPTION

A b/o script that provides the JSON data for generating BPOT graph chart.

=cut

package main;

use strict;
use warnings;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;

use List::Util qw( min max );
use JSON::MaybeXS;
use JSON::MaybeUTF8 qw(:v1);
use Format::Util::Numbers qw/financialrounding/;

use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use Finance::Contract::Longcode qw( shortcode_to_parameters );
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_JSON );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

# to complete a multiplier contract, we need limit order
my $limit_order = request()->param('limit_order');

my $bet;

if (my $shortcode = request()->param('shortcode') and my $currency = request()->param('currency')) {
    my $contract_parameters = shortcode_to_parameters($shortcode, $currency);
    $contract_parameters->{limit_order} = decode_json_utf8($limit_order) if $limit_order;
    $bet = produce_contract($contract_parameters);
}

unless ($bet) {
    PrintContentType();

    print "Error with shortcode '" . request()->param('shortcode') . "' and currency '" . request()->param('currency') . "'";
    code_exit_BO();
}

my $timestep = Time::Duration::Concise::Localize->new(interval => request()->param('timestep') || '24s');
my $start    = Date::Utility->new(request()->param('start')                                    || time());
my $end      = Date::Utility->new(request()->param('end')                                      || time());

my $data;
if ($bet->category_code eq 'multiplier') {
    $data = get_graph_data_for_multiplier($bet, $start, $end, $timestep);
} else {
    $data = get_graph_data_for_others($bet, $start, $end, $timestep);
}

sub get_graph_data_for_multiplier {
    my ($bet, $start, $end, $timestep) = @_;

    my $graph_more = 1;
    my $expired    = 0;
    my $show_date  = 1;
    my $when       = $start;

    # for multiplier, we would be mostly interested in profit&loss (PnL) and bid price
    my (@pnls, @bid_prices, @epochs, @spots);

    while ($graph_more) {
        $bet = make_similar_contract($bet, {priced_at => $when});

        if (not $bet->current_spot) {
            # do not proceed if spot is undefined
            $graph_more = 0;
        } else {
            if ($bet->is_expired) {
                $expired    = 1;    # One we know we've expired once, we can presume it stays expired.
                $graph_more = 0;    # Don't know when it ends, so when it expires, stop.
                push @pnls,       $bet->value - $bet->ask_price;
                push @bid_prices, $bet->bid_price + 0;
            } else {
                push @pnls,       $bet->current_pnl + 0;
                push @bid_prices, $bet->bid_price + 0;
            }

            push @epochs, $when->epoch;
            push @spots,  $bet->current_spot;
            if (!$when->is_before($end)) {
                $graph_more = 0;
            } else {
                my $next_step = $when->plus_time_interval($timestep);
                $show_date = ($next_step->days_between($when)) ? 1    : 0;          # Show the date only when we switch days.
                $when      = ($next_step->is_after($end))      ? $end : $next_step; # This makes the last step the wrong size sometimes, but so be it.
            }
        }
    }

    return {
        underlying_name => $bet->underlying->display_name,
        times           => \@epochs,
        time_title      => 'Time (' . $timestep->as_concise_string . ' steps)',
        data            => {
            'Spot'       => \@spots,
            'Bid Prices' => \@bid_prices,
            'PnLs'       => \@pnls,
            # not planning to change too much of graph javascript code.
            'Barriers(s)' => [],
            'Barriers2'   => [],
        },
    };
}

sub get_graph_data_for_others {
    my ($bet, $start, $end, $timestep) = @_;
    my (@times, @epochs, @spots, @barriers, @barriers2, @wins, @losses, @vs_changes);

    my ($barrier, $barrier2);
    if ($bet->two_barriers) {
        $barrier  = $bet->high_barrier->as_absolute;
        $barrier2 = $bet->low_barrier->as_absolute;
    } else {
        $barrier =
              ($bet->category->code eq 'digits') ? $bet->current_spot
            : ($bet->can('barrier') and defined $bet->barrier) ? $bet->barrier->as_absolute
            :                                                    undef;
        $barrier2 = $barrier;    # No idea how this might be changed by digit two barriers.
    }

    my $vs_date = $bet->volsurface->creation_date->datetime_iso8601;
    my %prices  = (
        theo_probability => [],
        ask_probability  => [],
        bid_probability  => [],
        iv               => [],
        mu               => [],
    );

    my $graph_more = 1;
    my $expired    = 0;
    my $show_date  = 1;
    my $when       = $start;

    my $value;

    while ($graph_more) {
        $bet = make_similar_contract($bet, {priced_at => $when});

        if (not $bet->current_spot) {
            $graph_more = 0;
        } else {
            if ($bet->is_expired) {
                $expired = 1;    # One we know we've expired once, we can presume it stays expired.
                $value = $bet->is_binary ? $bet->value / $bet->payout : $bet->value;    # Should go to 0 or 1 probability
                $graph_more = 0 if ($bet->tick_expiry);                                 # Don't know when it ends, so when it expires, stop.
            }
            my $date_string = $when->time_hhmmss;
            $date_string .= ' ' . $when->date_ddmmmyy if ($show_date);
            push @times,  $date_string;
            push @epochs, $when->epoch;
            push @spots,  $bet->current_spot;
            foreach my $attr (keys %prices) {
                my $amount;
                if ($attr !~ /probability/) {
                    # if it is not probability and it is not in pricing args, we should warn.
                    $amount = $expired ? 0 : $bet->_pricing_args->{$attr};
                    warn "$attr is not defined in \$bet->_pricing_args" unless defined $amount;
                } else {
                    next if not $bet->is_binary;
                    $amount = ($expired) ? $value : $bet->$attr->amount;
                }
                push @{$prices{$attr}}, financialrounding('amount', $bet->currency, (abs $amount > 3) ? $amount : $amount * 100);
            }

            my $current_vs = $bet->volsurface->creation_date->datetime_iso8601;
            push @vs_changes, scalar @times - 1 if ($vs_date ne $current_vs);
            $vs_date = $current_vs;

            push @barriers,  $barrier;
            push @barriers2, $barrier2;
            push @wins,      100;
            push @losses,    0;

            if (!$when->is_before($end)) {
                $graph_more = 0;
            } else {
                my $next_step = $when->plus_time_interval($timestep);
                $show_date = ($next_step->days_between($when)) ? 1    : 0;          # Show the date only when we switch days.
                $when      = ($next_step->is_after($end))      ? $end : $next_step; # This makes the last step the wrong size sometimes, but so be it.
            }
        }
    }

    return {
        underlying_name => $bet->underlying->display_name,
        times           => \@epochs,
        time_title      => 'Time (' . $timestep->as_concise_string . ' steps)',
        data            => {
            'Spot'        => \@spots,
            'Barriers(s)' => \@barriers,
            'Barriers2'   => \@barriers2,
            'Ask value'   => $prices{ask_probability},
            'Bid value'   => $prices{bid_probability},
            'Bet value'   => $prices{theo_probability},
            'Pricing IV'  => $prices{iv},
            'Pricing mu'  => $prices{mu},
            'wins'        => \@wins,
            'losses'      => \@losses,
            'vs_changes'  => \@vs_changes,
        },
    };
}

PrintContentType_JSON();
print JSON::MaybeXS->new->encode($data);


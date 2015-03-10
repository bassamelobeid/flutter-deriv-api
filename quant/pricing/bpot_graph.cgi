#!/usr/bin/perl

=head1 NAME

Bet Price Through Time: Graph image generation.

=head1 DESCRIPTION

A b/o page that generates and serves the actual BPOT graph image.

=cut

package main;

use strict;
use warnings;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;

use List::Util qw( min max );

use perlchartdir;

use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use BOM::Platform::Plack qw( PrintContentType_image );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

# Set Chart Director license key here
perlchartdir::setLicenseCode('RDST-2556-FV5X-NX9G-BD82-E751');

my $bet = produce_contract(request()->param('shortcode'), request()->param('currency'));

my $start = (request()->param('start')) ? BOM::Utility::Date->new(request()->param('start')) : $bet->date_start;
my $end =
      (request()->param('end')) ? BOM::Utility::Date->new(request()->param('end'))
    : ($bet->tick_expiry)       ? $bet->date_start->plus_time_interval($bet->max_tick_expiry_duration)
    :                             $bet->date_expiry;

if (request()->param('last')) {
    $start = BOM::Utility::Date->new({epoch => $start->epoch - request()->param('last') * 86400});
}

if ($end->epoch > time) {
    $end = BOM::Utility::Date->new;
}
my $duration = $end->epoch - $start->epoch;
my $interval = ($bet->tick_expiry) ? '1s' : request()->param('timestep') || max(1, int($duration / 20));
my $timestep = Time::Duration::Concise::Localize->new(interval => $interval);

if ($duration / $timestep->seconds > 500) {
    # Don't let them go crazy asking for thousands of points.
    $timestep = Time::Duration::Concise::Localize->new(interval => int($duration / 500));
}

my $barrier = ($bet->bet_type->category->code eq 'digits') ? $bet->current_spot : (defined $bet->barrier) ? $bet->barrier->as_absolute : undef;
my $barrier2 = ($bet->barrier2) ? $bet->barrier2->as_absolute : $barrier;    # No idea how this might be changed by digit two barriers.

my $vs_date = $bet->volsurface->recorded_date->datetime_iso8601;

my (@times, @spots, @barriers, @barriers2, @wins, @losses, @vs_changes);
my %prices = (
    theo_probability => [],
    ask_probability  => [],
    bid_probability  => [],
    bs_probability   => [],
    pricing_iv       => [],
    pricing_mu       => [],
);

my $step_epoch = $start->epoch;
my $graph_more = 1;
my $expired    = 0;
my $value;

while ($graph_more) {
    my $when = BOM::Utility::Date->new($step_epoch);
    $bet = make_similar_contract($bet, {priced_at => $when});

    if (not $bet->current_spot) {
        $graph_more = 0;
    } else {
        if ($bet->is_expired) {
            $expired    = 1;                             # One we know we've expired once, we can presume it stays expired.
            $value      = $bet->value / $bet->payout;    # Should go to 0 or 1 probability
            $graph_more = 0 if ($bet->tick_expiry);      # Don't know when it ends, so when it expires, stop.
        }
        push @times, $when->datetime;
        push @spots, $bet->current_spot;
        foreach my $attr (keys %prices) {
            my $amount = ($expired and $attr =~ /probability$/) ? $value : (ref $bet->$attr) ? $bet->$attr->amount : $bet->$attr;
            push @{$prices{$attr}}, roundnear(0.01, (abs $amount > 3) ? $amount : $amount * 100);
        }

        my $current_vs = $bet->volsurface->recorded_date->datetime_iso8601;
        push @vs_changes, scalar @times - 1 if ($vs_date ne $current_vs);
        $vs_date = $current_vs;

        push @barriers,  $barrier;
        push @barriers2, $barrier2;
        push @wins,      100;
        push @losses,    0;

        $graph_more = 0 if ($step_epoch >= $end->epoch);
        $step_epoch += $timestep->seconds;
        $step_epoch = min($step_epoch, $end->epoch);    # This makes the last step the wrong size sometimes, but so be it.
    }
}

my $c = XYChart->new(1200, 600);

# Set the plot area at (50, 20) and of size 200 x 130 pixels
$c->setPlotArea(80, 20, 1040, 440);

$c->xAxis->setTitle('Time (' . $timestep->as_concise_string . ' steps)');
$c->xAxis->setLabels(\@times);
$c->xAxis->setLabelStyle('', 12, '#000', 270);
my $steps_done = scalar @times;
$c->xAxis->setLabelStep(int($steps_done / 50), 1) if (scalar $steps_done > 50);

my @volsurface_colors = (0xe0e0e0, 0xf0f0f0);

while (scalar @vs_changes > 1) {
    my $start = shift @vs_changes;
    $c->xAxis->addZone($start, $vs_changes[0], $volsurface_colors[scalar @vs_changes % 2]);
}
$c->xAxis->addZone($vs_changes[0], scalar @times - 1, $volsurface_colors[0]);

# Add a legend box at (300, 70) (top center of the chart) with horizontal layout. Use
# # 8 pts Arial Bold font. Set the background and border color to Transparent.
my $legendBox = $c->addLegend(50, 580, 0, "arialbd.ttf", 10);
$legendBox->setAlignment($perlchartdir::BottomCenter);
$legendBox->setBackground($perlchartdir::Transparent, $perlchartdir::Transparent);

$c->yAxis->setTitle($bet->underlying->display_name);
$c->addLineLayer(\@spots,     0xa0a0a0, "Spot");
$c->addLineLayer(\@barriers,  0x800000, 'Barrier(s)');
$c->addLineLayer(\@barriers2, 0x800000, '');

$c->yAxis2->setTitle('%');
my @full_list = map { @{$prices{$_}} } keys %prices;
push @full_list, (@wins, @losses);

$c->yAxis2->setAutoScale(0.01, 0.01);

my $bsline = $c->addLineLayer2;
$bsline->addDataSet($prices{bs_probability}, 0x800080, 'BS value');
$bsline->setUseYAxis2;

my $priceline = $c->addLineLayer2;
$priceline->addDataSet($prices{theo_probability}, 0x000080, 'Bet value')->setDataSymbol($perlchartdir::DiamondSymbol, 5);
$priceline->setUseYAxis2;

my $ivline = $c->addLineLayer2;
$ivline->addDataSet($prices{pricing_iv}, 0xff8c00, 'Pricing IV');
$ivline->setUseYAxis2;

my $muline = $c->addLineLayer2;
$muline->addDataSet($prices{pricing_mu}, 0xcb6d51, 'Pricing mu');
$muline->setUseYAxis2;

my $winline = $c->addLineLayer2;
$winline->addDataSet(\@wins, 0x000000);
$winline->setUseYAxis2;

my $lossline = $c->addLineLayer2;
$lossline->addDataSet(\@losses, 0x000000);
$lossline->setUseYAxis2;

my $errlayer = $c->addBoxWhiskerLayer(
    undef, undef,
    $prices{ask_probability},
    $prices{bid_probability},
    $prices{theo_probability},
    $perlchartdir::Transparent, 0x336688,
);
$errlayer->setUseYAxis2;
$errlayer->setDataGap(0.8);

PrintContentType_image('png');
print $c->makeChart2($perlchartdir::PNG);

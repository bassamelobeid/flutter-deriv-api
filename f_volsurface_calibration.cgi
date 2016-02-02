#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::Market::UnderlyingDB;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use CGI;
use BOM::Platform::Sysinit ();
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::VolSurface::Moneyness;
use BOM::Market::Underlying;
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Backoffice::GDGraph;

BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('CALIBRATION MODEL COMPARISON');

BOM::Backoffice::Auth0::can_access(['Quants']);

my $cgi = CGI->new();
my @underlyings =
    ($cgi->param('underlyings'))
    ? split ',',
    $cgi->param('underlyings')
    : get_offerings_with_filter('underlying_symbol', {market => 'indices', contract_category => 'callput', barrier_category => 'euro_atm'});

my $calibrate = $cgi->param('calibrate');
my (%calibration_results, $template_name);
foreach my $underlying_symbol (@underlyings) {
    if ($calibrate) {
        $calibration_results{$underlying_symbol} = display($underlying_symbol);
        $template_name = 'backoffice/calibrator_param.html.tt';
    } else {
        $calibration_results{$underlying_symbol} =
            BOM::MarketData::VolSurface::Moneyness->new({underlying => BOM::Market::Underlying->new($underlying_symbol)})->parameterization || {};
        $template_name = 'backoffice/manual_update_calibration_param.html.tt';
    }
}

Bar('Update VolSurface Parameterization');
print process_param(\%calibration_results, $template_name);

sub process_param {
    my ($calibration_results, $template_name) = @_;

    my $html;
    BOM::Platform::Context::template->process(
        $template_name,
        {
            params          => $calibration_results,
            save_action_url => request()->url_for('backoffice/f_update_calibration.cgi'),
        },
        \$html
    ) || die BOM::Platform::Context::template->error;

    return $html;
}

sub display {
    my $underlying_symbol = shift;

    my %calibration_results;
    my $underlying = BOM::Market::Underlying->new($underlying_symbol);
    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({
        underlying => $underlying,
    });
    my $new_values            = $volsurface->compute_parameterization;
    my $new_parameterization  = $new_values->{values};
    my $new_calibration_error = $new_values->{calibration_error};
    my %rounded_params        = map { $_ => roundnear(0.00001, $new_parameterization->{$_}) } keys %$new_parameterization;
    $calibration_results{calibration_param} = \%rounded_params;
    my $implied_surface        = $volsurface->surface;
    my $surface_with_new_param = $volsurface->clone({
            parameterization => {
                values            => $new_parameterization,
                calibration_error => $new_calibration_error,
            },
        });
    my $calibrated_implied_surface = $surface_with_new_param->calibrated_surface;

    my $display_calibrated;
    my $display_implied;
    foreach my $tenor (keys %$calibrated_implied_surface) {
        %{$display_calibrated->{$tenor}} =
            map { $_ => roundnear(0.0001, $calibrated_implied_surface->{$tenor}->{$_}) } keys %{$calibrated_implied_surface->{$tenor}};
        %{$display_implied->{$tenor}} =
            map { $_ => roundnear(0.0001, $implied_surface->{$tenor}->{smile}->{$_}) } keys %{$implied_surface->{$tenor}->{smile}};
    }

    $calibration_results{calibration_error}                     = $surface_with_new_param->calibration_error;
    $calibration_results{calibrated}                            = $display_calibrated;
    $calibration_results{smilepoints}                           = $volsurface->smile_points;
    $calibration_results{implied_volsurface}{surface}           = $display_implied;
    $calibration_results{implied_volsurface}{recorded_datetime} = $volsurface->recorded_date->datetime_iso8601;

    my @x_axis                       = sort { $a <=> $b } @{$volsurface->moneynesses};
    my @tenor                        = sort { $a <=> $b } @{$volsurface->term_by_day};
    my @implied_surface_volpoints    = map  { values %{$implied_surface->{$_}->{smile}} } @tenor;
    my @calibrated_surface_volpoints = map  { values %{$calibrated_implied_surface->{$_}} } @tenor;
    my $y_max_value = (sort { $a <=> $b } (@implied_surface_volpoints, @calibrated_surface_volpoints))[-1];
    foreach my $term (@tenor) {
        my @implied_smile    = map { $implied_surface->{$term}->{smile}->{$_}   || undef } @x_axis;
        my @calibrated_smile = map { $calibrated_implied_surface->{$term}->{$_} || undef } @x_axis;
        my $calib_filename   = BOM::Backoffice::GDGraph::generate_line_graph({
                title  => "Plot comparison for $term day smile",
                x_axis => \@x_axis,
                charts => {
                    first => {
                        label_name => 'original_smile',
                        data       => \@implied_smile
                    },
                    second => {
                        label_name => 'original_calibrated_smile',
                        data       => \@calibrated_smile
                    },
                },
                y_max_value => roundnear(0.001, $y_max_value * 1.1),
                x_label     => 'smile_points',
                y_label     => 'Volatility',
            });
        $calibration_results{implied_vs_calib}{$term} = request()->url_for('temp/' . $calib_filename);
    }

    return \%calibration_results;
}

#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Market::Underlying;
use BOM::Platform::Runtime;
use BOM::Utility::Graph::GD;
use BOM::Platform::Plack qw( PrintContentType_JSON );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

use CGI;
use List::Util qw(max);
use JSON qw(to_json from_json);
use Try::Tiny;
use URL::Encode qw(url_decode);

my $cgi    = CGI->new();
my $symbol = $cgi->param('symbol');
my ($ori_param, $altered_param) = map { $cgi->param($_) } qw(ori altered);
$altered_param = from_json($altered_param);

my $response;
try {
    my $underlying = BOM::Market::Underlying->new($symbol);
    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new()->fetch_surface({
        underlying => $underlying,
    });
    my %ori_surface = map { $_ => $volsurface->surface->{$_}->{smile} } keys %{$volsurface->surface};
    my $calibrated_surface = $volsurface->clone({parameterization => {values => from_json($ori_param)}})->calibrated_surface();
    my $altered_volsurface = $volsurface->clone({parameterization => {values => $altered_param}});
    my @altered_param_in_array     = map { $altered_param->{$_} } @{$altered_volsurface->calibration_param_names};
    my $new_calibration_error      = $altered_volsurface->function_to_optimize(\@altered_param_in_array);
    my $altered_calibrated_surface = $altered_volsurface->calibrated_surface();

    my $display_altered;
    foreach my $tenor (keys %$altered_calibrated_surface) {
        %{$display_altered->{$tenor}} =
            map { $_ => roundnear(0.0001, $altered_calibrated_surface->{$tenor}->{$_}) } keys %{$altered_calibrated_surface->{$tenor}};
    }

    my @x_axis = @{$volsurface->moneynesses};
    my $GD     = BOM::Utility::Graph::GD->new();
    my $new_graphs;
    my @tenor = sort @{$volsurface->term_by_day};
    my $y_max_value = max map { values %{$ori_surface{$_}}, values %{$calibrated_surface->{$_}}, values %{$altered_calibrated_surface->{$_}} } @tenor;
    foreach my $term (@tenor) {
        my @ori_smile                = map { $ori_surface{$term}->{$_}                  || undef } @x_axis;
        my @ori_calibrated_smile     = map { $calibrated_surface->{$term}->{$_}         || undef } @x_axis;
        my @altered_calibrated_smile = map { $altered_calibrated_surface->{$term}->{$_} || undef } @x_axis;
        my $calib_filename           = $GD->generate_img({
                title  => "Plot comparison for $term day smile",
                x_axis => \@x_axis,
                charts => {
                    first => {
                        label_name => 'original_smile',
                        data       => \@ori_smile
                    },
                    second => {
                        label_name => 'original_calibrated_smile',
                        data       => \@ori_calibrated_smile
                    },
                    third => {
                        label_name => 'altered_calibrated_smile',
                        data       => \@altered_calibrated_smile
                    },
                },
                x_label     => 'smile_points',
                y_label     => 'Volatility',
                y_max_value => roundnear(0.001, $y_max_value * 1.1),
            });
        $new_graphs->{$term} = request()->url_for('temp/' . $calib_filename);
    }
    $response = {
        success               => 1,
        new_graphs            => to_json($new_graphs),
        new_surface           => to_json($display_altered),
        new_calibration_error => $new_calibration_error,
    };
}
catch { $response = {success => 0, reason => $_} };

PrintContentType_JSON();
print to_json($response);
code_exit_BO();

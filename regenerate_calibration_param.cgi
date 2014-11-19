#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::Market::PricingInputs::Couch::VolSurface;
use BOM::Market::Underlying;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType_JavaScript );

system_initialize();

use CGI;
use JSON qw(to_json from_json);
use Try::Tiny;

my $cgi           = CGI->new();
my $symbol        = $cgi->param('symbol');
my $initial_guess = from_json($cgi->param('initial_guess'));

my $underlying = BOM::Market::Underlying->new($symbol);
my $volsurface = BOM::Market::PricingInputs::Couch::VolSurface->new()->fetch_surface({underlying => $underlying,});

my $clone = $volsurface->clone({parameterization => {values => $initial_guess}});
my $response;
try {
    my $new_calibration_param = $clone->compute_parameterization->{values};
    my %param_for_display = map { $_ => roundnear(0.00001, $new_calibration_param->{$_}) } keys %$new_calibration_param;
    $response = {
        success    => 1,
        new_params => to_json(\%param_for_display),
    };
}
catch {
    $response = {
        success => 0,
        reason  => $_,
    };
};

PrintContentType_JavaScript();
print to_json($response);
code_exit_BO();

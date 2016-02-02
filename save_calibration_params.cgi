#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::MarketData::Display::VolatilitySurface;
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Moneyness;
use Format::Util::Numbers qw(roundnear);
use Date::Utility;

use JSON qw(to_json);
use CGI;

my $cgi                   = CGI->new();
my $underlying_symbol     = $cgi->param('underlying');
my $underlying            = BOM::Market::Underlying->new($underlying_symbol);
my $volsurface            = BOM::MarketData::VolSurface::Moneyness->new({underlying => $underlying});
my @param_names           = @{$volsurface->calibration_param_names};
my %new_params            = map { $_ => $cgi->param($_) } @param_names;
my @param_in_array        = map { $new_params{$_} } @param_names;
my $new_calibration_error = $volsurface->function_to_optimize(\@param_in_array);
my $clone_volsurface      = $volsurface->clone({
        parameterization => {
            values            => \%new_params,
            date              => Date::Utility->new->datetime_iso8601,
            calibration_error => $new_calibration_error,
        }});

eval { $clone_volsurface->save };

my $success = {success => 1};

if (my $error = $@) {
    $success->{success} = 0;
    $success->{reason}  = $error;
}

print to_json($success);

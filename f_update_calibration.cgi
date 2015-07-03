#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Market::Underlying;
use BOM::Platform::Runtime;
use Date::Utility;
use BOM::Platform::Plack qw( PrintContentType_JSON );
use BOM::Platform::Sysinit ();

use CGI;
use JSON qw(from_json);
use Try::Tiny;

BOM::Platform::Sysinit::init();

BOM::Backoffice::Auth0::can_access(['Quants']);

my $cgi = CGI->new();

my $dm                 = BOM::MarketData::Fetcher::VolSurface->new();
my $underlying         = BOM::Market::Underlying->new($cgi->param('symbol'));
my $surface            = $dm->fetch_surface({underlying => $underlying});
my %calibration_params = map { $_ => $cgi->param($_) } @{$surface->calibration_param_names};
my $calibration_error  = $cgi->param('calibration_error_' . $cgi->param('symbol'));

my $clone = $surface->clone({
        parameterization => {
            values            => \%calibration_params,
            date              => Date::Utility->new->datetime_iso8601,
            calibration_error => $calibration_error
        }});

my $response = {
    success => 1,
};

try { $clone->save } catch { $response = {success => 0, reason => $_} };

PrintContentType_JSON();
print to_json($response);
code_exit_BO();

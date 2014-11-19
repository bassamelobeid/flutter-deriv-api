#!/usr/bin/perl
package main;

=head1 NAME

validate_surface.cgi

=head1 DESCRIPTION

Handles AJAX validation of surfaces.

=cut

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use CGI;
use JSON qw( from_json to_json );
use URL::Encode qw( url_decode );

use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType_JavaScript );
use BOM::Market::PricingInputs::VolSurface::Helper::SurfaceValidator;
system_initialize();

# Our very own %input processing logic seems to strip
# out characters from my URL encoded JSON, breaking it.
my $cgi           = CGI->new;
my $underlying    = BOM::Market::Underlying->new($cgi->param('symbol'));
my $recorded_date = BOM::Utility::Date->new($cgi->param('recorded_epoch'));
my $type          = $cgi->param('type');
my $spot          = $cgi->param('spot');

my $surface_string = url_decode($cgi->param('surface'));
$surface_string =~ s/point/./g;
my $surface_data = from_json($surface_string);

my $class = 'BOM::Market::PricingInputs::VolSurface::' . ($type eq 'moneyness' ? 'Moneyness' : 'Delta');
my $surface;

eval {
    $surface = $class->new(
        underlying     => $underlying,
        surface        => $surface_data,
        recorded_date  => $recorded_date,
        spot_reference => $spot,
    );

    BOM::Market::PricingInputs::VolSurface::Helper::SurfaceValidator->new->validate_surface($surface);
};

my $response = {success => 1};
if (my $e = $@ || $surface->get_smile_flags) {
    $response = {
        success => 0,
        reason  => (ref $e ? $e->message : $e)};
}

PrintContentType_JavaScript();
print to_json($response);
code_exit_BO();

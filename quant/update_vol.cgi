#!/usr/bin/perl
package main;

=head1 NAME

update_vol.cgi

=head1 DESCRIPTION

Handles moneyness update AJAX requests; saves submitted surfaces to Couch.

=cut

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use CGI;
use JSON qw( from_json to_json );
use URL::Encode qw( url_decode );

use BOM::Platform::Plack qw( PrintContentType_JavaScript );
use BOM::Market::PricingInputs::VolSurface::Helper::SurfaceValidator;

use f_brokerincludeall;
system_initialize();

# Our very own %input processing logic seems to strip
# out characters from my URL encoded JSON, breaking it.
my $cgi           = CGI->new;
my $underlying    = BOM::Market::Underlying->new($cgi->param('symbol'));
my $which         = $cgi->param('which');
my $spot          = $cgi->param('spot');
my $recorded_date = BOM::Utility::Date->new($cgi->param('recorded_epoch'));

my $surface_string = url_decode($cgi->param('surface'));
$surface_string =~ s/point/./g;
my $surface_data = from_json($surface_string);

eval {
    my $surface = BOM::Market::PricingInputs::VolSurface::Moneyness->new(
        underlying     => $underlying,
        surface        => $surface_data,
        recorded_date  => $recorded_date,
        spot_reference => $spot,
    );

    BOM::Market::PricingInputs::VolSurface::Helper::SurfaceValidator->new->validate_surface($surface);

    $surface->save;
};

my $response = {success => 1};
if ($@) {
    $response = {
        success => 0,
        reason  => (ref $@ ? $@->message : $@)};
}

PrintContentType_JavaScript();
print to_json($response);
code_exit_BO();

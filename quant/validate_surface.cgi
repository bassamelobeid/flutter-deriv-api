#!/etc/rmg/bin/perl
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
use JSON::MaybeXS;
use URL::Encode qw( url_decode );
use BOM::MarketData qw(create_underlying);

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType_JSON );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

# Our very own %input processing logic seems to strip
# out characters from my URL encoded JSON, breaking it.
my $cgi           = CGI->new;
my $underlying    = create_underlying($cgi->param('symbol'));
my $creation_date = Date::Utility->new($cgi->param('recorded_epoch'));
my $type          = $cgi->param('type');
my $spot          = $cgi->param('spot');

my $surface_string = url_decode($cgi->param('surface'));
$surface_string =~ s/point/./g;
my $surface_data = JSON::MaybeXS->new->decode($surface_string);

my $class = 'Quant::Framework::VolSurface::' . ($type eq 'moneyness' ? 'Moneyness' : 'Delta');
my $surface;

$surface = $class->new(
    underlying     => $underlying,
    surface        => $surface_data,
    creation_date  => $creation_date,
    spot_reference => $spot,
);

my $response;
if ($surface->is_valid) {
    $response->{success} = 1;
} else {
    $response = {
        success => 0,
        reason  => $surface->validation_error,
    };
}

PrintContentType_JSON();
print JSON::MaybeXS->new->encode($response);
code_exit_BO();

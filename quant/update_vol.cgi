#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use CGI;
use JSON qw( from_json to_json );
use BOM::MarketData qw(create_underlying);
use URL::Encode qw( url_decode );

use BOM::Backoffice::PlackHelpers qw( PrintContentType_JSON );

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

# Our very own %input processing logic seems to strip
# out characters from my URL encoded JSON, breaking it.
my $cgi           = CGI->new;
my $underlying    = create_underlying($cgi->param('symbol'));
my $which         = $cgi->param('which');
my $spot          = $cgi->param('spot');
my $creation_date = Date::Utility->new($cgi->param('recorded_epoch'));

my $surface_string = url_decode($cgi->param('surface'));
$surface_string =~ s/point/./g;
my $surface_data = from_json($surface_string);

my $surface = Quant::Framework::VolSurface::Moneyness->new(
    underlying     => $underlying,
    surface        => $surface_data,
    creation_date  => $creation_date,
    spot_reference => $spot,
);

my $response;
if ($surface->is_valid) {
    $surface->save;
    $response->{success} = 1;
} else {
    $response = {
        success => 0,
        reason  => $surface->validation_error,
    };
}

PrintContentType_JSON();
print to_json($response);
code_exit_BO();

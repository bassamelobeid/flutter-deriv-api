#!/usr/bin/perl
package main;
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use List::Util qw( first );

use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Market::PricingInputs::Couch::VolSurface;
use BOM::Market::PricingInputs::Volatility::Display;
system_initialize();

PrintContentType();
BOM::Platform::Auth0::can_access(['Quants']);
my $display;
my $symbol     = request()->param('symbol');
my $underlying = BOM::Market::Underlying->new($symbol);

my $dm               = BOM::Market::PricingInputs::Couch::VolSurface->new;
my $existing         = $dm->fetch_surface({underlying => $underlying});
my $existing_surface = eval { $existing->surface };

my $volsurface = ($existing_surface) ? $existing : undef;
if ($volsurface) {
    $display = BOM::Market::PricingInputs::Volatility::Display->new(surface => $volsurface);
}

print '<html><head><title>Editing volsurface for ' . $symbol . '</title></head>';
print '<body style="background-color:white;">';
print '<table border="0" cellpadding="5" cellspacing="5"><tr><td valign="top">';
print '<form action="' . request()->url_for('backoffice/f_save.cgi') . '" method="post" name="editform">';
print '<input type="hidden" name="filen" value="editvol">';
print '<input type="hidden" name="symbol" value="' . $symbol . '">';
print '<input type="hidden" name="l" value="EN">';
print '<textarea name="text" rows="15" cols="50">';

if ($display) {
    print join "\n", $display->rmg_text_format;
    print '</textarea>';
    if (first { $_ eq 'spot_reference' } keys %{$existing->meta->{attributes}}) {
        print 'Spot reference: <input type="text" name="spot_reference" value="' . $existing->spot_reference . '">';
    }
} else {
    print '</textarea>';
    print 'Spot reference: <input type="text" name="spot_reference">';
}

print '<input type="submit" value="Save.">';
print '</td><td>';

if (my $index_price = $underlying->spot > 0) {
    print "<b>5\% down=" . (int($index_price * 0.95 / 10) * 10);
    print " 5\% up=" . (int($index_price * 1.05 / 10) * 10) . "</b>";
}

print "</td></tr></table>";
print "</form>";

code_exit_BO();

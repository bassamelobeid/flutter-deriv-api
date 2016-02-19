#!/usr/bin/perl
package main;
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use Quant::Framework::InterestRate;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BOM::Backoffice::Auth0::can_access(['Quants']);

my $currency_symbol = request()->param('symbol');
my $existing_interest_rate = Quant::Framework::InterestRate->new({symbol => $currency_symbol})->rates;

Bar("Updates $currency_symbol rates");
print '<html><head><title>Editing interest rate files for ' . $currency_symbol . '</title></head>';
print '<body style="background-color:white;">';
print '<table border="0" cellpadding="5" cellspacing="5"><tr><td valign="top">';
print '<form action="' . request()->url_for('backoffice/f_save.cgi') . '" method="post" name="editform">';
print '<input type="hidden" name="filen" value="vol/master' . $currency_symbol . '.interest">';
print '<input type="hidden" name="l" value="EN">';
print '<textarea name="text" rows="15" cols="50">';

foreach my $term (sort { $a <=> $b } keys %{$existing_interest_rate}) {
    print "$term $existing_interest_rate->{$term}\n";
}
print '</textarea>';
print '<input type="submit" value="Save.">';
print '</td><td>';
print "</form>";

code_exit_BO();

#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use open qw[ :encoding(UTF-8) ];
use Format::Util::Numbers qw(commas);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use HTML::Entities;

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BOM::Backoffice::Auth0::can_access(['Quants']);

my $filename      = request()->param('show');
my $displayport   = request()->param('displayport');
my $outputlargest = request()->param('outputlargest');
my $viewonlylist  = request()->param('viewonlylist');

print "<TABLE border=1>";

my $F = "<font size=2 face=verdana><b>";
print
    "<TR><TD>$F LOGINID</TD><TD>$F LIVEorDEAD</TD><TD>$F A/C BALANCE</TD><TD>$F OPEN P/L</TD><TD>$F TOTAL EQUITY AT MKT</TD><TD>$F AGGREGATE DEPOSITS<br>& WITHDRAWALS</TD><TD>$F MARKED-TO-MARKET<br>PROFIT/LOSS</TD>";
print "<TD>$F AGG. PAYOUTS OF<br>OUTSTANDING BETS</TD>";
if ($displayport) { print "<TD>$F PORTFOLIO</TD>"; }
print "</TR>";

my @sums;
my @fields;

my @to_out;

if (open(my $fh, '<', $filename)) {    ## no critic (RequireBriefOpen)
    flock($fh, 1);

    while (my $l = <$fh>) {
        if ($l =~ /^\#/) { print "<TR><TD colspan=8><font size=2 face=verdana><b>$l</td></tr>"; }
        else {
            @fields = split(/\,/, $l);
            my $thislineout = "\r<TR>";

            my $i = 0;
            foreach my $f (@fields) {
                if ($i == 6) {
                    #calculate aggregate payout of outstanding bets
                    my @hisportfolio = split /\+/, $f;
                    my $aggpayouts = 0;
                    foreach my $h (@hisportfolio) {
                        if ($h =~ /^(\d+)L\s(\d*\.?\d*)\s([^_]+)\_([^_]+)\_(\d+)/) { $aggpayouts += $5; }
                    }
                    $thislineout .= "<TD><font size=2 face=verdana>" . encode_entities($aggpayouts) . "</TD>";

                    $f =~ s/\+/<br>/g;
                }
                if (($displayport) || ($i < 6)) {
                    $thislineout .= "<TD><font size=2 face=verdana>" . encode_entities($f) . "</TD>";
                    if (abs($f) > 0) { $sums[$i] += $f; }

                    if ($i == 5) {
                        $thislineout .= "<TD><font size=2 face=verdana>" . encode_entities(commas($fields[4] - $fields[5])) . "</TD>";
                    }    #marked-to-market profit/loss
                }

                $i++;
            }

            if   (request()->param('sortby') == 6) { $thislineout .= "<!-- " . encode_entities($fields[4] - $fields[5]) . " -->"; }
            else                                   { $thislineout .= "<!-- " . encode_entities($fields[request()->param('sortby')]) . " -->"; }
            $thislineout .= "</TR>";

            if (not $viewonlylist or $viewonlylist =~ /$fields[0]/) { push @to_out, $thislineout; }
        }
    }

    close($fh);
} else {
    print "Can not open " . encode_entities($filename);
}

my @s_to_out;
if (request()->param('sortorder') =~ /reverse/) {
    @s_to_out =
        sort { my ($a1, $b1); $a =~ /\<\!\-\-\s(\-?\d*\.?\d*)\s/; $a1 = $1; $b =~ /\<\!\-\-\s(\-?\d*\.?\d*)\s/; $b1 = $1; $a1 <=> $b1; } @to_out;
} else {
    @s_to_out =
        sort { my ($a1, $b1); $a =~ /\<\!\-\-\s(\-?\d*\.?\d*)\s/; $a1 = $1; $b =~ /\<\!\-\-\s(\-?\d*\.?\d*)\s/; $b1 = $1; $b1 <=> $a1; } @to_out;
}

splice @s_to_out, $outputlargest;
print @s_to_out;

print "<TR>";
my $i = 0;
foreach my $f (@fields) {
    if   (abs($sums[$i]) > 0) { print "<TD><B><font size=2 face=verdana> " . encode_entities(commas($sums[$i])) . "</TD>"; }
    else                      { print "<TD></TD>"; }
    $i++;
}
print "</TR>";
print "</table>";
print "<P><font size=2 face=verdana><b>Sum of all client overall marked-to-market profits since inception : "
    . (int(100 * ($sums[4] - $sums[5])) / 100);
print "<P>";

code_exit_BO();

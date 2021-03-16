#!/etc/rmg/bin/perl

=head1 NAME

update_used_volatilities.cgi

=head1 DESCRIPTION

Purpose: To check/verify/update our volsurfaces in backoffice.

Note: relevant Bloomberg pages

For forex:
VM Volatility Monitors
OVDV Currency Volatility Surface
MRKT Market (to get vols contributed by different banks)

For indices:
TRMS Term Structure
HIVG Historical Implied Volatility Graph

IMPORTANT! If using NDX (Nasdaq-100) vols, then deduct about 1.5%
to arrive at Nasdaq Composite (CCMP) vols

To know which indices we get in realtime:  EXCH
Another way:  DAX Index EXC
To filter the entire stock universide: QSRC <go> 28 <go>

SOME JARGONS WE CREATED LONG LONG AGO
-------------------------------------

USED VOLATILITY
This is the volatility currently in use, thus the existing vol surface.

IMPLIED VOLATILITY
This is the volatility from the feeds. As of this writing, these feeds are updated by quants uploading
manually Excel files or from Bloomberg (automatic cron).

FUTURE VOLATILITY
This is the volatility to be updated replacing the existing surface. Most of the time, this is the same
with the implied volatility (except if we make manual changes)

=cut

package main;

use strict;
use warnings;

use List::MoreUtils qw( uniq );
use HTML::Entities;
use Syntax::Keyword::Try;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use Quant::Framework::VolSurface::Delta;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::MarketData::Display::VolatilitySurface;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use Finance::Asset::Market::Registry;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

my @all_markets = Finance::Asset::Market::Registry->instance->all_market_names();
my @update_markets;
foreach my $market (@all_markets) {
    push @update_markets, $market if request()->param('update_$market');
}

my $update_including_intraday_double = request()->param('update_including_intraday_double');
my $markets                          = request()->param('markets');

# To give a warning when difference between old and new vol is too big
my $warndifference = 0.1;

my @markets;
push @markets, split /\s+/, $markets if $markets;
if ($update_including_intraday_double) {
    push @markets,
        create_underlying_db->get_symbols_for(
        market            => \@update_markets,
        contract_category => 'ANY',
        );
} else {
    push @markets,
        create_underlying_db->get_symbols_for(
        market            => \@update_markets,
        contract_category => 'IV',
        );
}

my $dm = BOM::MarketData::Fetcher::VolSurface->new;

# Get various volatilty surfaces
my %volatility_surfaces;
foreach my $market (@markets) {

    my $underlying = create_underlying($market);
    # when we are updating surface, fetch New York 10 for FX
    my $args = {
        underlying => $underlying,
    };
    my $volsurface = $dm->fetch_surface($args);
    my ($existing_surface, $err);
    try {
        $existing_surface = $volsurface->surface;
    } catch ($e) {
        $err = $e;
    }
    $volsurface = undef unless $existing_surface;
    $volatility_surfaces{$market} = {
        used      => $volsurface,
        errorused => $err
    };
}

BrokerPresentation('Update Volatility');

my $now = Date::Utility->new;
Bar('Update Volatility ' . $now->date_ddmmmyy . '   ' . $now->hour . $now->minute . ' GMT');

print q~<table class='full-width'>~;
print '<tr>';
print '<td>';
print get_update_volatilities_form({
    'selected_markets' => $markets,
    'warndifference'   => $warndifference,
    'all_markets'      => \@all_markets
});
print '</td>';
print q~<td align=right>~;
print "<form method=post action='" . request()->url_for('backoffice/quant/market_data_mgmt/update_volatilities/save_used_volatilities.cgi') . "'>";
print "<input type=hidden name=markets value='" . encode_entities($markets) . "'>";
print "<input type=hidden name=warndifference value='" . encode_entities($warndifference) . "'>";
print "<input id='confirm_volatility' type=submit class='btn btn--red' value='Confirm all'>";
print "</form>";
print '</td>';
print '</tr>';
print '</table>';

foreach my $market (@markets) {
    Bar("$market matrices");

    print '<table class="border">';
    print '<TR>';

    # The 'Volatily in Use'
    print '<TD>';
    if (not $volatility_surfaces{$market}->{'errorused'}) {
        if ($volatility_surfaces{$market}->{used}) {
            print BOM::MarketData::Display::VolatilitySurface->new(surface => $volatility_surfaces{$market}->{used})->html_volsurface_in_table;
        } else {
            print "Surface does not exist";
        }
    } else {
        print "An error occurred: ' " . encode_entities($volatility_surfaces{$market}->{'errorused'}) . "'.";
    }
    print "</TD>";
    print "</TR>";
    print '</table>';
}

code_exit_BO();

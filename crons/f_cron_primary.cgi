#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

BEGIN {
    push @INC, "/home/git/regentmarkets/bom/cgi", "/home/git/regentmarkets/bom-backoffice/lib", "/home/git/regentmarkets/bom-backoffice/subs";

}

use Date::Utility;
use BOM::Backoffice::Sysinit ();

use subs::subs_backoffice_removeexpired;
use subs::subs_backoffice_reports;
use LandingCompany::Registry;

BOM::Backoffice::Sysinit::init();

my $now  = Date::Utility->new;
my $hour = $now->hour;
my $wday = $now->day_of_week;

if ($hour == 22 and $wday == 6) {

    foreach my $bc (LandingCompany::Registry::all_broker_codes) {
        if ($bc =~ /^VR/)                                                     { next; }
        if (LandingCompany::Registry->get_by_broker($bc)->country eq 'Malta') { next; }    #due to LGA regulations
        if ($bc eq 'MLT')                                                     { next; }    #double check to be 100% sure!
        Rescind_FreeGifts($bc, 180, 'Do it for real !');
    }

}

1;

#!/usr/bin/perl
package main;
use strict 'vars';

BEGIN {
    push @INC, "/home/git/regentmarkets/bom/cgi";
}

use Date::Utility;
use BOM::Backoffice::Sysinit ();

use subs::subs_backoffice_removeexpired;
use subs::subs_backoffice_reports;
use BOM::Platform::Runtime::LandingCompany::Registry;

BOM::Backoffice::Sysinit::init();

my $now  = Date::Utility->new;
my $hour = $now->hour;
my $wday = $now->day_of_week;

if ($hour == 22 and $wday == 6) {

    foreach my $bc (BOM::Platform::Runtime::LandingCompany::Registry::all_broker_codes) {
        if ($bc =~ /^VRT/) {next;}
        if (BOM::Platform::Runtime::LandingCompany::Registry::get_by_broker($bc)->country eq 'Malta') { next; }    #due to LGA regulations
        if ($bc eq 'MLT') { next; }                                                                                    #double check to be 100% sure!
        Rescind_FreeGifts($bc, 180, 'Do it for real !');
    }

}

1;

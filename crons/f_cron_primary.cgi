#!/usr/bin/perl
package main;
use strict 'vars';

BEGIN {
    push @INC, "/home/git/bom/cgi";
}

use include_common_modules;
use subs::subs_files;

use BOM::Platform::Runtime;
use subs::subs_backoffice_security;
use subs::subs_backoffice_statistics;
use subs::subs_backoffice_removeexpired;
use subs::subs_backoffice_reports;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

my $now  = BOM::Utility::Date->new;
my $hour = $now->hour;
my $wday = $now->day_of_week;

if ($hour == 22 and $wday == 6) {
    my $runtime = BOM::Platform::Runtime->instance;
    my @broker_codes = map { $_->code } grep { not $_->is_virtual } $runtime->broker_codes->get_brokers_on_server($runtime->hosts->localhost);

    foreach my $bc (@broker_codes) {
        if (BOM::Platform::Runtime->instance->broker_codes->landing_company_for($bc)->country eq 'Malta') { next; }    #due to LGA regulations
        if ($bc eq 'MLT') { next; }                                                                                    #double check to be 100% sure!
        Rescind_FreeGifts($bc, 180, 'Do it for real !');
    }

}

1;

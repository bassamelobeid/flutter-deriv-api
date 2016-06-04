#!/usr/bin/perl
package main;

use strict;
use warnings;

use Date::Utility;
use BOM::System::Localhost;
use BOM::Platform::Email qw(send_email);
use BOM::MyAffiliates::BackfillManager;
use BOM::Platform::Sysinit ();
use BOM::Platform::Runtime;

BOM::Platform::Sysinit::init();

my $runtime = Date::Utility->new;

my $backfill_manager            = BOM::MyAffiliates::BackfillManager->new;
my @backfill_promo_codes_report = $backfill_manager->backfill_promo_codes;

my $full_report = ['Mark First Deposits:', ''];
push @{$full_report}, ('', 'Promo Codes:', '');
push @{$full_report}, @backfill_promo_codes_report;

send_email({
    from    => 'system@binary.com',
    to      => BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email,
    subject => 'CRON backfill_affiliate_data: Report from ' . BOM::System::Localhost::name() . ' for ' . $runtime->datetime_yyyymmdd_hhmmss_TZ,
    message => $full_report,
});

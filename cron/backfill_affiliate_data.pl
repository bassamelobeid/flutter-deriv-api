#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Date::Utility;
use BOM::Platform::Email qw(send_email);
use BOM::MyAffiliates::BackfillManager;

local $SIG{ALRM} = sub { die "alarm\n" };
alarm 1800;

my $runtime = Date::Utility->new;

my $backfill_manager            = BOM::MyAffiliates::BackfillManager->new;
my @backfill_promo_codes_report = $backfill_manager->backfill_promo_codes;

my $full_report = ['Mark First Deposits:', ''];
push @{$full_report}, ('', 'Promo Codes:', '');
push @{$full_report}, @backfill_promo_codes_report;

send_email({
    from    => 'system@binary.com',
    to      => 'affiliates@binary.com',
    subject => 'CRON backfill_affiliate_data: Report for ' . $runtime->datetime_yyyymmdd_hhmmss_TZ,
    message => $full_report,
});

#!/usr/bin/perl
package main;

=head1 NAME

myaffiliates/backfill_affiliate_data.pl

=head1 DESCRIPTION

su nobody -c "perl /home/git/regentmarkets/bom-backoffice/crons/myaffiliates/backfill_affiliate_data.pl"

=cut

use strict;
use warnings;

use BOM::Utility::Log4perl;
use Date::Utility;
use BOM::System::Localhost;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::MyAffiliates::BackfillManager;
use BOM::Platform::Sysinit ();
use BOM::Platform::Runtime;

BOM::Utility::Log4perl::init_log4perl_console;
BOM::Platform::Sysinit::init();

my $runtime = Date::Utility->new;

my $backfill_manager            = BOM::Platform::MyAffiliates::BackfillManager->new;
my @backfill_promo_codes_report = $backfill_manager->backfill_promo_codes;

my $full_report = ['Mark First Deposits:', ''];
push @{$full_report}, ('', 'Promo Codes:', '');
push @{$full_report}, @backfill_promo_codes_report;

send_email({
    from    => 'system@binary.com',
    to      => BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email,
    subject => 'CRON backfill_affiliate_data: Report from '
        . BOM::System::Localhost::name() . ' for '
        . $runtime->datetime_yyyymmdd_hhmmss_TZ,
    message => $full_report,
});

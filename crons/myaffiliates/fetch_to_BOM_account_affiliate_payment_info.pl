#!/usr/bin/perl
package main;

=head1 NAME

myaffiliates/fetch_to_BOM_account_affiliate_payment_info.pl

=head1 DESCRIPTION

su nobody -c "perl /home/git/regentmarkets/bom-backoffice/crons/myaffiliates/fetch_to_BOM_account_affiliate_payment_info.pl"

=cut

use strict;
use warnings;
use Getopt::Long;
use Text::CSV;
use IO::File;
use BOM::Utility::Log4perl;
use BOM::Platform::MyAffiliates::PaymentToBOMAccountManager;
use BOM::Platform::Email qw(send_email);
use include_common_modules;

BOM::Utility::Log4perl::init_log4perl_console;
system_initialize();

my $runtime = BOM::Utility::Date->new;

# get arg if any
my ($from_arg, $to_arg);
my $opt_result = GetOptions(
    'from=s' => \$from_arg,
    'to=s'   => \$to_arg,
);
if (not $opt_result) {
    print STDERR 'Usage: ' . $0 . ' [--from=RMGdatetime --to=RMGdatetime]';
    exit;
}

# define period that we're requesting over
my ($from, $to);
if ($from_arg and $to_arg) {
    $from = BOM::Utility::Date->new($from_arg);
    $to   = BOM::Utility::Date->new($to_arg);
} else {
    $to =
      BOM::Utility::Date->new(BOM::Utility::Date->new('1-' . $runtime->month_as_string . '-' . $runtime->year_in_two_digit . ' 00:00:00')->epoch - 1);
    $from = BOM::Utility::Date->new('1-' . $to->month_as_string . '-' . $to->year_in_two_digit . ' 00:00:00');
}

my @csv_file_locs = BOM::Platform::MyAffiliates::PaymentToBOMAccountManager->new(
    from => $from,
    to   => $to
)->get_csv_file_locs;

my @message = ('"To BOM Account" affiliate payment CSVs are attached for review and upload into the affiliate payment backoffice tool.');
if (grep { $_ =~ /ERRORS/ } @csv_file_locs) {
    push @message, '';
    push @message,
      'NOTE: There are reported ERRORS. Please CHECK AND FIX the erroneous transactions in MyAffiliates then work with SWAT to rerun the cronjob.';
}

send_email({
        from    => BOM::Platform::Runtime->instance->app_config->system->email,
        to      => BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email,
        subject => 'CRON fetch_to_BOM_account_affiliate_payment_info: Report from '
          . BOM::Platform::Runtime->instance->hosts->localhost->canonical_name . ' for '
          . $runtime->datetime_yyyymmdd_hhmmss_TZ,
        message    => \@message,
        attachment => \@csv_file_locs,
});

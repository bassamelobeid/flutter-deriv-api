#!/usr/bin/perl
package main;
use strict 'vars';

use Getopt::Long;
use Text::CSV;
use IO::File;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::MyAffiliates::PaymentToBOMAccountManager;
use BOM::Platform::Email qw(send_email);

use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('Myaffiliate Payment');

BOM::Platform::Auth0::can_access(['Marketing']);

Bar('Myaffiliate Payment Info');

unless (request()->param('from') and request()->param('to')) {
    print "Invalid FROM / TO date";
    code_exit_BO();
}

my $from = BOM::Utility::Date->new(request()->param('from'));
my $to   = BOM::Utility::Date->new(request()->param('to'));

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
    subject => 'Fetch Myaffiliates payment info: (' . $from->datetime_yyyymmdd . ' - ' . $to->datetime_yyyymmdd . ')',
    message    => \@message,
    attachment => \@csv_file_locs,
});

print "Fetch Myaffiliates payment done, info has been emailed to " . BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email;
code_exit_BO();

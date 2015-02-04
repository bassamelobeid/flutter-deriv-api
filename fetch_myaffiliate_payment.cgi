#!/usr/bin/perl
package main;
use strict 'vars';

use Getopt::Long;
use Text::CSV;
use IO::File;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::MyAffiliates::PaymentToBOMAccountManager;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(request);
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use f_brokerincludeall;

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

my $pid = fork;
if (not defined $pid) {
    print "An error has occurred";
} elsif ($pid) {
    waitpid $pid, 0;
    if ($?) {
        print "An error has occurred";
    } else {
        print "Fetch Myaffiliates payment triggered, info will be emailed soon to " . BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email;
    }
} else {
    # 1st, break parent/child relationship
    $pid = fork;
    exit 1 unless defined $pid;
    exit 0 if $pid;

    # next daemonize
    close STDIN;
    open STDIN, '<', '/dev/null';
    close STDOUT;
    open STDOUT, '>', '/dev/null';
    require POSIX;
    POSIX::setsid;
    send_email({
        from       => BOM::Platform::Runtime->instance->app_config->system->email,
        to         => BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email,
        subject    => 'Fetch Myaffiliates payment info: (' . $from->date_yyyymmdd . ' - ' . $to->date_yyyymmdd . ')',
        message    => \@message,
        attachment => \@csv_file_locs,
    });
    exit 0;
}

code_exit_BO();

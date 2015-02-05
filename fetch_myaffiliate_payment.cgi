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

my $pid = fork;
if (not defined $pid) {
    print "An error has occurred -- cannot fork";
} elsif ($pid) {
    waitpid $pid, 0;
    if ($?) {
        print "An error has occurred -- child comes back with $?";
    } else {
        print "Fetch Myaffiliates payment triggered, info will be emailed soon to " . BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email;
    }
} else {
    # 1st, break parent/child relationship
    require POSIX;
    $pid = fork;
    POSIX::_exit 1 unless defined $pid;
    POSIX::_exit 0 if $pid;

    # next daemonize
    for my $fd (0,1,3..1000) {
        POSIX::close $fd;
    }

    request()->http_handler->suppress_flush=1;
    request()->http_handler->binmode_ok=1;
    {
        no warnings 'uninitialized';
        binmode STDIN;
        open STDIN, '<', '/dev/null';

        binmode STDOUT;
        open STDOUT, '>', '/dev/null';
    }

    $0 = "fetch myaffiliate payment info worker";
    POSIX::setsid;

    $SIG{ALRM} = sub {POSIX::_exit 19};
    alarm 3600;

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
        from       => BOM::Platform::Runtime->instance->app_config->system->email,
        to         => 'torsten@binary.com',  #BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email,
        subject    => 'Fetch Myaffiliates payment info: (' . $from->date_yyyymmdd . ' - ' . $to->date_yyyymmdd . ')',
        message    => \@message,
        attachment => \@csv_file_locs,
    });
    POSIX::_exit 0;
}

code_exit_BO();

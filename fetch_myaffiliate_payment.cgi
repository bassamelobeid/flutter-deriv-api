#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Getopt::Long;
use Text::CSV;
use IO::File;
use Try::Tiny;
use Fcntl qw/:flock O_RDWR O_CREAT/;
use Brands;
use BOM::MyAffiliates::PaymentToAccountManager;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::Config qw/get_tmp_path_or_die/;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use f_brokerincludeall;

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation('Myaffiliate Payment');

Bar('Myaffiliate Payment Info');

unless (request()->param('from') and request()->param('to')) {
    print "Invalid FROM / TO date";
    code_exit_BO();
}

my $from    = Date::Utility->new(request()->param('from'));
my $to      = Date::Utility->new(request()->param('to'));
my $tmp_dir = get_tmp_path_or_die();

my $lf = '/var/run/bom-daemon/fetch_myaffiliate_payment.lock';

sysopen my $lock, $lf, O_RDWR | O_CREAT or do {
    print "Cannot open $lf: $!\n";
    code_exit_BO();
};

flock $lock, LOCK_EX | LOCK_NB or do {
    print "Cannot lock $lf. There is probably another process still doing pretty much the same thing.\n";
    code_exit_BO();
};

my $pid = fork;
if (not defined $pid) {
    print "An error has occurred -- cannot fork";
} elsif ($pid) {
    waitpid $pid, 0;
    if ($?) {
        print "An error has occurred -- child comes back with $?";
    } else {
        print "Fetch Myaffiliates payment triggered, info will be emailed soon to " . Brands->new(name => request()->brand)->emails('affiliates');
    }
} else {
    # 1st, break parent/child relationship
    require POSIX;
    $pid = fork;
    POSIX::_exit 1 unless defined $pid;
    POSIX::_exit 0 if $pid;

    truncate $lock, 0;
    syswrite $lock, "$$\n";

    # next daemonize
    for my $fd (0 .. 1000) {
        next if $fd == fileno $lock;
        POSIX::close $fd;
    }

    POSIX::open("/dev/null", POSIX::O_RDONLY());    # stdin
    POSIX::open("/dev/null", POSIX::O_WRONLY());    # stdout
    POSIX::open("/dev/null", POSIX::O_WRONLY());    # stderr

    $0 = "fetch myaffiliate payment info worker";  ## no critic (RequireLocalizedPunctuationVars)
    POSIX::setsid;

    $SIG{ALRM} = sub { truncate $lock, 0; POSIX::_exit 19 };    ## no critic (RequireLocalizedPunctuationVars)
    alarm 900;

    try {
        my @csv_file_locs = BOM::MyAffiliates::PaymentToAccountManager->new(
            from    => $from,
            to      => $to,
            tmp_dir => $tmp_dir,
        )->get_csv_file_locs;

        my @message = ('"To BOM Account" affiliate payment CSVs are attached for review and upload into the affiliate payment backoffice tool.');
        if (grep { $_ =~ /ERRORS/ } @csv_file_locs) {
            push @message, '';
            push @message,
                'NOTE: There are reported ERRORS. Please CHECK AND FIX the erroneous transactions in MyAffiliates then work with SWAT to rerun the cronjob.';
        }

        my $brand = Brands->new(name => request()->brand);
        send_email({
            from       => $brand->emails('system'),
            to         => $brand->emails('affiliates'),
            subject    => 'Fetch Myaffiliates payment info: (' . $from->date_yyyymmdd . ' - ' . $to->date_yyyymmdd . ')',
            message    => \@message,
            attachment => \@csv_file_locs,
        });
        truncate $lock, 0;
    }
    catch {
        warn("Error: $_");
    };

    POSIX::_exit 0;
}

code_exit_BO();

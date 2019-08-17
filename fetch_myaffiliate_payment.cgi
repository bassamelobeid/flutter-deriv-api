#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no indirect;

use Digest::MD5;
use Path::Tiny;
use Try::Tiny;
use Fcntl qw/:flock O_RDWR O_CREAT/;
use BOM::MyAffiliates::PaymentToAccountManager;
use BOM::Config;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::Config qw/get_tmp_path_or_die/;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Platform::S3Client;
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

my $expiry  = 3600;                    # 1 hour
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

try {
    my $from = Date::Utility->new(request()->param('from'));
    my $to   = Date::Utility->new(request()->param('to'));
    my $zip  = path(
        BOM::MyAffiliates::PaymentToAccountManager->new(
            from    => $from,
            to      => $to,
            tmp_dir => $tmp_dir,
        )->get_csv_zip
    );
    my $csum = Digest::MD5->new->addfile($zip->openr)->hexdigest;

    my $s3_client = BOM::Platform::S3Client->new(BOM::Config::third_party()->{myaffiliates});
    try {
        $s3_client->upload($zip->basename, $zip, $csum)->get;
    }
    catch {
        die "Upload failed for @{[ $zip->basename ]}: $!";
    };

    my @message =
        ('"To BOM Account" affiliate payment CSVs zip archive is linked below for review and upload into the affiliate payment backoffice tool.');
    push @message, '';
    push @message,
        'NOTE: There may be reported ERRORS; if so, please CHECK AND FIX the erroneous transactions in MyAffiliates then work with SWAT to rerun the cronjob.';

    push @message, '';
    push @message, 'Please find the generated payment reports archive at the link below:';
    push @message, 'NOTE: The link below is valid for 1 hour from the time of request, please download it immediately before this link expires.';
    push @message, '';
    push @message, $s3_client->get_s3_url($zip->basename, $expiry);

    my $brand = request()->brand;
    send_email({
        from    => $brand->emails('system'),
        to      => $brand->emails('affiliates'),
        subject => 'Fetch Myaffiliates payment info: (' . $from->date_yyyymmdd . ' - ' . $to->date_yyyymmdd . ')',
        message => \@message,
    });
    truncate $lock, 0;

    print "Fetch Myaffiliates payment triggered, info will be emailed soon to " . $brand->emails('affiliates');
}
catch {
    my $error = $_;

    warn "Error: $error";
    $error =~ s/at .*$//;
    print "An error has occurred -- $error\n";
};

code_exit_BO();

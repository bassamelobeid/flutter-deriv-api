use strict;
use warnings;

use Getopt::Long;
use Path::Tiny;
use Date::Utility;
use File::stat;
use YAML qw(LoadFile);
use IO::Async::Loop;
use Try::Tiny;
use Archive::Zip qw( :ERROR_CODES );
use Net::Async::Webservice::S3;
use Amazon::S3::SignedURLGenerator;

use Brands;

use BOM::Config::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::MyAffiliates::ActivityReporter;

local $SIG{ALRM} = sub { die "alarm\n" };
alarm 1800;

my $cpa_type = $ARGV[0] // undef;

my $to_date = Date::Utility->new(time - 86400);
#Alway start to regenerate the files from start of the month.
my $from_date = Date::Utility->new('01-' . $to_date->month_as_string . '-' . $to_date->year);

my $reporter        = BOM::MyAffiliates::ActivityReporter->new();
my $processing_date = Date::Utility->new($from_date->epoch);

my $output_dir = BOM::Config::Runtime->instance->app_config->system->directory->db . '/myaffiliates/';
path($output_dir)->mkpath if (not -d $output_dir);

my $output_zip = $cpa_type ? "${cpa_type}_" : "myaffiliates_";
$output_zip .= $from_date->date_yyyymmdd . "-" . $to_date->date_yyyymmdd . ".zip";

my $output_zip_path = path("/tmp/$output_zip");
my $zip             = Archive::Zip->new();

while ($to_date->days_between($processing_date) >= 0) {
    my $output_filename = $output_dir;
    if ($cpa_type) {
        $output_filename .= "${cpa_type}_";
    } else {
        $output_filename .= "pl_";
    }

    $output_filename .= $processing_date->date_yyyymmdd . '.csv';

    # check if file exist and is not of size 0
    if (-e $output_filename and stat($output_filename)->size > 0) {
        $processing_date = Date::Utility->new($processing_date->epoch + 86400);
        next;
    }

    my @csv = $reporter->activity_for_date_as_csv($processing_date->date_ddmmmyy, $cpa_type);

    # Date, Player, P&L, Deposits, Runbet Turnover, Intraday Turnover, Other Turnover
    my @lines;
    foreach my $line (@csv) {
        chomp $line;
        push @lines, $line . "\n" if $line;
    }
    path($output_filename)->spew_utf8(@lines);
    $zip->addFile($output_filename, path($output_filename)->basename);

    $processing_date = Date::Utility->new($processing_date->epoch + 86400);
}

die "unable to create zip file at: ${\$output_zip_path->stringify}" unless ($zip->writeToFileNamed($output_zip_path->stringify) == AZ_OK);

my $config = LoadFile('/etc/rmg/third_party.yml')->{myaffiliates};
my $loop   = IO::Async::Loop->new;
my $s3     = Net::Async::Webservice::S3->new(
    access_key => $config->{aws_access_key_id},
    secret_key => $config->{aws_secret_access_key},
    bucket     => $config->{aws_bucket},
);
$loop->add($s3);

my $url_generator = Amazon::S3::SignedURLGenerator->new(
    aws_access_key_id     => $config->{aws_access_key_id},
    aws_secret_access_key => $config->{aws_secret_access_key},
    prefix                => "https://$config->{aws_bucket}.s3.amazonaws.com/",
    expires               => 24 * 3600
);

try {
    $s3->put_object(
        key   => $output_zip,
        value => $output_zip_path->slurp
    )->get;
    my $download_url = $url_generator->generate_url('GET', $output_zip);

    my $brand = Brands->new();
    # email CSV out for reporting purposes
    send_email({
        from    => $brand->emails('system'),
        to      => $brand->emails('affiliates'),
        subject => 'CRON generate_affiliate_PL_daily: ' . ' for date range ' . $from_date->date_yyyymmdd . ' - ' . $to_date->date_yyyymmdd,
        message => ["Find links to download CSV that was generated:\n" . $download_url],
    });
}
catch {
    die "Failed to upload reports to s3. Error is $_. No email was sent.";
};

use strict;
use warnings;

use Future;
use Getopt::Long;
use Path::Tiny;
use Try::Tiny;
use Date::Utility;
use File::stat;
use IO::Async::Loop;
use Net::Async::Webservice::S3;
use Amazon::S3::SignedURLGenerator;

use Brands;

use BOM::Platform::Email qw(send_email);
use BOM::MyAffiliates::ActivityReporter;
use BOM::Platform::Runtime;

local $SIG{ALRM} = sub { die "alarm\n" };
alarm 1800;

my $to_date = Date::Utility->new(time - 86400);
#Alway start to regenerate the files from start of the month.
my $from_date = Date::Utility->new('01-' . $to_date->month_as_string . '-' . $to_date->year);

my $reporter        = BOM::MyAffiliates::ActivityReporter->new();
my $processing_date = Date::Utility->new($from_date->epoch);
my @csv_filenames;

my $loop = IO::Async::Loop->new;
my $s3 = Net::Async::Webservice::S3->new(
   access_key => $ENV{AFFILIATES_AUTH_S3_ACCESS},
   secret_key => $ENV{AFFILIATES_AUTH_S3_SECRET},
   bucket     => $ENV{AFFILIATES_AUTH_S3_BUCKET},
);
$loop->add($s3);


my $url_generator = Amazon::S3::SignedURLGenerator->new(
    aws_access_key_id     => $ENV{AFFILIATES_AUTH_S3_ACCESS},
    aws_secret_access_key => $ENV{AFFILIATES_AUTH_S3_SECRET},
    prefix                => "https://$ENV{AFFILIATES_AUTH_S3_BUCKET}.s3.amazonaws.com/",
    expires               => BOM::Platform::Runtime->instance->app_config->system->mail->download_duration,
);

my $output_dir = BOM::Platform::Runtime->instance->app_config->system->directory->db . '/myaffiliates/';
path($output_dir)->mkpath if (not -d $output_dir);

while ($to_date->days_between($processing_date) >= 0) {
    my $output_filename = $output_dir . 'pl_' . $processing_date->date_yyyymmdd . '.csv';

    # check if file exist and is not of size 0
    if (-e $output_filename and stat($output_filename)->size > 0) {
        $processing_date = Date::Utility->new($processing_date->epoch + 86400);
        next;
    }

    my @csv = $reporter->activity_for_date_as_csv($processing_date->date_ddmmmyy);

    # Date, Player, P&L, Deposits, Runbet Turnover, Intraday Turnover, Other Turnover
    my @lines;
    foreach my $line (@csv) {
        chomp $line;
        push @lines, $line . "\n" if $line;
    }
    path($output_filename)->spew_utf8(@lines);

    push @csv_filenames, $output_filename;

    $processing_date = Date::Utility->new($processing_date->epoch + 86400);
}

# upload generated files to s3
my @upload_futures;
my @download_urls;
foreach my $file_path (@csv_filenames) {
    my $csv_file_path = path($file_path);
    my $put_future = $s3->put_object(
        key   => $csv_file_path->basename,
        value => $csv_file_path->slurp_utf8
    );
    push @upload_futures, $put_future;
    push @download_urls, $url_generator->generate_url('GET', path($file_path)->basename);
}

try {
    Future->needs_all(@upload_futures)->get;
    
    my $brand = Brands->new();
    my $urls_email_body = join "\n", @download_urls;
    # email CSV out for reporting purposes
    send_email({
        from       => $brand->emails('system'),
        to         => $brand->emails('affiliates'),
        subject    => 'CRON generate_affiliate_PL_daily: ' . ' for date range ' . $from_date->date_yyyymmdd . ' - ' . $to_date->date_yyyymmdd,
        message    => ["Find links to download CSV that was generated:\n" . $urls_email_body],
    });
}
catch {
    warn "Failed to upload reports to s3: " . shift . "Email won't be sent also";
}
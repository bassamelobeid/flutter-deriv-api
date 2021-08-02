use strict;
use warnings;
no indirect;

use Path::Tiny;
use Syntax::Keyword::Try;
use Date::Utility;
use Log::Any qw($log);
use Getopt::Long 'GetOptions';
use DataDog::DogStatsd;
use Archive::Zip qw( :ERROR_CODES );

use Brands;

use BOM::MyAffiliates::ActivityReporter;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'd|past_date=s' => \my $past_date,
    'b|brand=s'     => \my $brand,
    'l|log=s'       => \my $log_level,
);

$log_level ||= 'warn';
Log::Any::Adapter->import(
    qw(DERIV),
    stdout    => 'text',
    log_level => $log_level
);

local $SIG{ALRM} = sub { die "alarm\n" };
alarm 1800;

if ($past_date) {
    try {
        Date::Utility->new($past_date);
    } catch {
        die 'Invalid date. Please use yyyy-mm-dd format.';
    }
}

my $to_date   = Date::Utility->new($past_date // (time - 86400));
my $from_date = Date::Utility->new('01-' . $to_date->month_as_string . '-' . $to_date->year);

my $statsd          = DataDog::DogStatsd->new;
my $processing_date = Date::Utility->new($from_date->epoch);

my $zip = Archive::Zip->new();

my $brand_object = Brands->new(name => $brand);
my @warn_msgs;

my $reporter = BOM::MyAffiliates::ActivityReporter->new(
    processing_date => $processing_date,
    brand           => $brand_object,
);

my $output_dir = $reporter->directory_path();
$output_dir->mkpath unless $output_dir->exists;

die "Unable to create $output_dir" unless $output_dir->exists;

while ($to_date->days_between($processing_date) >= 0) {
    my $next_date = Date::Utility->new($processing_date->epoch + 86400);

    $reporter = BOM::MyAffiliates::ActivityReporter->new(
        processing_date => $processing_date,
        brand           => $brand_object
    );

    my $output_filepath = $reporter->output_file_path();
    # check if file exist and is not of size 0
    if ($output_filepath->exists and $output_filepath->stat->size > 0) {
        push @warn_msgs,
              "There is already a file $output_filepath with size "
            . $output_filepath->stat->size
            . " created at "
            . Date::Utility->new($output_filepath->stat->mtime)->datetime;
        $processing_date = $next_date;
        next;
    }

    try {
        my @csv = $reporter->activity();
        unless (@csv) {
            $log->infof('No CSV data for affiliate turnover report for %s', $processing_date->date_yyyymmdd) unless @csv;
            push @warn_msgs, 'No CSV data for affiliate turnover report for ' . $processing_date->date_yyyymmdd unless @csv;
            $processing_date = $next_date;
            next;
        }

        $output_filepath->spew_utf8(@csv);
        $log->debugf('Data file name %s created.', $output_filepath);
        $zip->addFile($output_filepath->stringify, $output_filepath->basename);
    } catch ($error) {
        $statsd->event('Failed to generate MyAffiliates PL report', "MyAffiliates PL report failed to generate csv files due: $error");
        push @warn_msgs, "failed to generate report $output_filepath due: $error";
    }

    $processing_date = $next_date;
}

my $output_zip =
      "myaffiliates_"
    . $brand_object->name . '_'
    . $reporter->output_file_prefix()
    . $from_date->date_yyyymmdd . "-"
    . $to_date->date_yyyymmdd . ".zip";
my $output_zip_path = path("/tmp")->child($output_zip)->stringify;
try {
    unless ($zip->numberOfMembers) {
        $statsd->event('Failed to generate MyAffiliates PL report', 'MyAffiliates PL report generated an empty zip archive');
        $log->warnf("Generated empty zip file %s, the related warnings are: \n%s", $output_zip_path, join("\n-", @warn_msgs));
        exit 1;
    }

    unless ($zip->writeToFileNamed($output_zip_path) == AZ_OK) {
        $statsd->event('Failed to generate MyAffiliates PL report', "MyAffiliates PL report failed to generate zip archive");
        $log->warn("Failed to generate MyAffiliates PL report: MyAffiliates PL report failed to generate zip archive");
        exit 1;
    }
} catch ($error) {
    $statsd->event('Failed to generate MyAffiliates PL report', "MyAffiliates PL report failed to generate zip archive with $error");
    $log->warnf("Failed to generate MyAffiliates PL report: MyAffiliates PL report failed to generate zip archive with %s", $error);
    exit 1;
}

try {
    my $download_url = $reporter->download_url(
        output_zip => {
            name => $output_zip,
            path => $output_zip_path
        });

    $log->debugf('Sending email for affiliate profit and loss report');
    $reporter->send_report(
        subject => 'CRON generate_affiliate_PL_daily ('
            . $brand_object->name
            . ') for date range '
            . $from_date->date_yyyymmdd . ' - '
            . $to_date->date_yyyymmdd,
        message => ["Find links to download CSV that was generated:\n" . $download_url],
    );
} catch ($error) {
    $statsd->event('Failed to generate MyAffiliates PL report', "MyAffiliates PL report failed to upload to S3 due: $error");
    $log->warnf("Failed to generate MyAffiliates PL report: MyAffiliates PL report failed to upload to S3 due to: %s", $error);
    exit 1;
}

1;

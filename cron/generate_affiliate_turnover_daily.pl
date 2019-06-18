use strict;
use warnings;
no indirect;

use Path::Tiny;
use Try::Tiny;
use Date::Utility;
use Getopt::Long 'GetOptions';

use Brands;

use BOM::MyAffiliates::TurnoverReporter;
use BOM::Config::Runtime;
use BOM::Platform::Email qw/send_email/;
use DataDog::DogStatsd;

GetOptions
    'past_date=s' => \my $past_date;

if ($past_date) {
    try {
        Date::Utility->new($past_date);
    } catch {
        die 'Invalid date. Please use yyyy-mm-dd format.';
    };
}

my $reporter        = BOM::MyAffiliates::TurnoverReporter->new();
my $statsd          = DataDog::DogStatsd->new;
my $processing_date = Date::Utility->new($past_date // (time - 86400));
my @csv;

try {
    @csv = $reporter->activity_for_date_as_csv($processing_date->date_ddmmmyy);
} catch {
    my $error = shift;
    $statsd->event('Turnover Report Failed', "TurnoverReporter failed to generate csv files due: $error");
};

unless (@csv) {
    $statsd->event('Turnover Report Failed', 'Turnover report has no data for ' . $processing_date->date_ddmmmyy);
    exit;
}

my $output_dir = BOM::Config::Runtime->instance->app_config->system->directory->db . '/myaffiliates/';
path($output_dir)->mkpath if (not -d $output_dir);

my $output_filename = $output_dir . 'turnover_' . $processing_date->date_yyyymmdd . '.csv';

my @lines;
push @lines, $reporter->get_headers_for_csv . "\n";
foreach my $line (@csv) {
    chomp $line;
    push @lines, $line . "\n" if $line;
}

# in case if write was not successful
try {
    path($output_filename)->spew_utf8(@lines);

    my $brand = Brands->new();
    # email CSV out for reporting purposes
    send_email({
        from       => $brand->emails('system'),
        to         => $brand->emails('affiliates'),
        subject    => 'CRON generate_affiliate_turnover_daily ' . ' for date ' . $processing_date->date_yyyymmdd,
        message    => ['Find attached the CSV that was generated.'],
        attachment => $output_filename,
    });
} catch {
    my $error = shift;
    $statsd->event('Turnover Report Failed', "TurnoverReporter failed to write and send the csv files due: $error");
};

1;

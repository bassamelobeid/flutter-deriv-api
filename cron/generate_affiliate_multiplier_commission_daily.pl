#!/usr/bin/env perl

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

use BOM::MyAffiliates::MultiplierReporter;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'd|past_date=s' => \my $past_date,
    'b|brand=s'     => \my $brand,
    'l|log=s'       => \my $log_level,
);

$log_level ||= 'error';
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

if ($past_date) {
    try {
        Date::Utility->new($past_date);
    }
    catch {
        die 'Invalid date. Please use yyyy-mm-dd format.';
    }
}

my $brand_object = Brands->new(name => $brand);

try {
    my $processing_date = Date::Utility->new($past_date // (time - 86400));
    my $reporter = BOM::MyAffiliates::MultiplierReporter->new(
        processing_date => $processing_date,
        brand           => $brand_object,
    );

    my @csv = $reporter->activity();
    $log->infof('No CSV data for affiliate multiplier report for %s', $processing_date->date_yyyymmdd) unless @csv;
    die "No CSV data for " . $processing_date->date_yyyymmdd unless @csv;

    my $output_dir = $reporter->directory_path();
    $output_dir->mkpath unless ($output_dir->exists);

    exit "Unable to create $output_dir" unless $output_dir->exists;

    my $output_filepath = $reporter->output_file_path();
    $output_filepath->spew_utf8(@csv);
    $log->debugf('Data file name %s created.', $output_filepath);

    my $zip        = Archive::Zip->new();
    $zip->addFile($output_filepath->stringify, $output_filepath->basename);

    $log->debugf('Sending email for affiliate multiplier report');

    my $output_zip = "myaffiliates_" . $brand_object->name . '_' . $reporter->output_file_prefix() . $processing_date->date_yyyymmdd . ".zip";
    my $output_zip_path = path("/tmp")->child($output_zip)->stringify;

    my $statsd          = DataDog::DogStatsd->new;

    my @warn_msgs;
    try {
        unless ($zip->numberOfMembers) {
            $statsd->event('Failed to generate MyAffiliates multiplier report', 'MyAffiliates multiplier report generated an empty zip archive');
            warn "Generated empty zip file $output_zip_path, the related warnings are: \n", join "\n-", @warn_msgs;
            exit 1;
        }

        unless ($zip->writeToFileNamed($output_zip_path) == AZ_OK) {
            $statsd->event('Failed to generate MyAffiliates multiplier report', "MyAffiliates multiplier report failed to generate zip archive");
            warn 'Failed to generate MyAffiliates multiplier report: ', "MyAffiliates multiplier report failed to generate zip archive";
            exit 1;
        }
    }
    catch {
        my $error = $@;
        $statsd->event('Failed to generate MyAffiliates multiplier report', "MyAffiliates multiplier report failed to generate zip archive with $error");
        warn 'Failed to generate MyAffiliates multiplier report: ', "MyAffiliates multiplier report failed to generate zip archive with $error";
        exit 1;
    }

    my $download_url = $reporter->download_url(
        output_zip => {
            name => $output_zip,
            path => $output_zip_path
        });

    $reporter->send_report(
        subject    => 'CRON generate_affiliate_multiplier_commission_daily (' . $brand_object->name . ') for date ' . $processing_date->date_yyyymmdd,
        message => ["Find links to download CSV that was generated:\n" . $download_url],
    );
}
catch {
    my $error = $@;
    DataDog::DogStatsd->new->event('Affiliate Multiplier Report Failed', "MultiplierReporter failed to generate csv files due: $error");
    warn "MultiplierReporter failed to generate csv files due to: $error";
    exit 1;
}

1;

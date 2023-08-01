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

use BOM::MyAffiliates::ContractsWithSpreadReporter;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'd|past_date=s'         => \my $past_date,
    'b|brand=s'             => \my $brand,
    'l|log=s'               => \my $log_level,
    'c|contract_category=s' => \my $contract_category,
);

$log_level ||= 'warn';
Log::Any::Adapter->import(
    qw(DERIV),
    stdout    => 'text',
    log_level => $log_level
);

if ($past_date) {
    try {
        Date::Utility->new($past_date);
    } catch {
        die 'Invalid date. Please use yyyy-mm-dd format.';
    }
}

my $brand_object = Brands->new(name => $brand);

try {
    my $processing_date = Date::Utility->new($past_date // (time - 86400));
    my $reporter        = BOM::MyAffiliates::ContractsWithSpreadReporter->new(
        processing_date   => $processing_date,
        brand             => $brand_object,
        contract_category => $contract_category,
    );

    my @csv = $reporter->activity();
    $log->infof('No CSV data for affiliate ' . $contract_category . ' report for %s', $processing_date->date_yyyymmdd) unless @csv;
    die "No CSV data for " . $processing_date->date_yyyymmdd                                                           unless @csv;

    my $output_dir = $reporter->directory_path();
    $output_dir->mkpath unless ($output_dir->exists);

    exit "Unable to create $output_dir" unless $output_dir->exists;

    my $output_filepath = $reporter->output_file_path();
    $output_filepath->spew_utf8(@csv);
    $log->debugf('Data file name %s created.', $output_filepath);

    my $zip = Archive::Zip->new();
    $zip->addFile($output_filepath->stringify, $output_filepath->basename);

    $log->debugf("Sending email for affiliate $contract_category report");

    my $output_zip      = "myaffiliates_" . $brand_object->name . '_' . $reporter->output_file_prefix() . $processing_date->date_yyyymmdd . ".zip";
    my $output_zip_path = path("/tmp")->child($output_zip)->stringify;

    my $statsd = DataDog::DogStatsd->new;

    my @warn_msgs;
    try {
        unless ($zip->numberOfMembers) {
            $statsd->event(
                "Failed to generate MyAffiliates $contract_category report",
                "MyAffiliates $contract_category report generated an empty zip archive"
            );
            $log->warnf("Generated empty zip file %s, the related warnings are: \n %s", $output_zip_path, join("\n-", @warn_msgs));
            exit 1;
        }

        unless ($zip->writeToFileNamed($output_zip_path) == AZ_OK) {
            $statsd->event(
                "Failed to generate MyAffiliates $contract_category report",
                "MyAffiliates $contract_category report failed to generate zip archive"
            );
            $log->warn(
                "Failed to generate MyAffiliates $contract_category report: MyAffiliates $contract_category report failed to generate zip archive");
            exit 1;
        }
    } catch ($error) {
        $statsd->event("Failed to generate MyAffiliates $contract_category report",
            "MyAffiliates $contract_category report failed to generate zip archive with $error");
        $log->warnf(
            "Failed to generate MyAffiliates $contract_category report: MyAffiliates $contract_category report failed to generate zip archive with %s",
            $error
        );
        exit 1;
    }

    my $download_url = $reporter->download_url(
        output_zip => {
            name => $output_zip,
            path => $output_zip_path
        });

    $reporter->send_report(
        subject => 'CRON generate_affiliate_contracts_with_spread_commission_daily ('
            . $brand_object->name
            . ') for date '
            . $processing_date->date_yyyymmdd
            . ' for contract category: '
            . $contract_category,
        message => ["Find links to download CSV that was generated:\n" . $download_url],
    );
} catch ($error) {
    DataDog::DogStatsd->new->event("Affiliate $contract_category Report Failed",
        "ContractsWithSpreadReporter failed to generate csv files due: $error");
    $log->warnf("ContractsWithSpreadReporter failed to generate csv files for $contract_category due to: %s", $error);
    exit 1;
}

1;

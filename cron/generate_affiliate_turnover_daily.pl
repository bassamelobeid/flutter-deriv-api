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

use Brands;

use BOM::MyAffiliates::TurnoverReporter;

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
    my $reporter = BOM::MyAffiliates::TurnoverReporter->new(
        processing_date => $processing_date,
        brand           => $brand_object,
    );

    my @csv = $reporter->activity();
    $log->infof('No CSV data for affiliate turnover report for %s', $processing_date->date_yyyymmdd) unless @csv;
    die "No CSV data for " . $processing_date->date_yyyymmdd unless @csv;

    my $output_dir = $reporter->directory_path();
    $output_dir->mkpath unless ($output_dir->exists);

    exit "Unable to create $output_dir" unless $output_dir->exists;

    my $output_filepath = $reporter->output_file_path();
    $output_filepath->spew_utf8(@csv);
    $log->debugf('Data file name %s created.', $output_filepath);

    $log->debugf('Sending email for affiliate turnover report');
    $reporter->send_report(
        subject    => 'CRON generate_affiliate_turnover_daily (' . $brand_object->name . ') for date ' . $processing_date->date_yyyymmdd,
        message    => ['Find attached the CSV that was generated.'],
        attachment => $output_filepath->stringify,
    );
}
catch {
    my $error = $@;
    DataDog::DogStatsd->new->event('Affiliate Turnover Report Failed', "TurnoverReporter failed to generate csv files due: $error");
    warn "TurnoverReporter failed to generate csv files due to: $error";
    exit 1;
}

1;

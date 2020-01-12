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

$log->infof('%s, %s, %s', $log_level, $brand, $past_date);

if ($past_date) {
    try {
        Date::Utility->new($past_date);
    }
    catch {
        die 'Invalid date. Please use yyyy-mm-dd format.';
    }
}

my $statsd          = DataDog::DogStatsd->new;
my $processing_date = Date::Utility->new($past_date // (time - 86400));
my $reporter        = BOM::MyAffiliates::TurnoverReporter->new(
    processing_date => $processing_date,
    brand           => Brands->new(name => $brand));

my @csv;
my $output_filepath;
try {
    @csv = $reporter->activity();
    $log->infof('No CSV data for affiliate turnover report for %s', $processing_date->date_yyyymmdd) unless @csv;
    die "No CSV data for " . $processing_date->date_yyyymmdd unless @csv;

    my $output_dir = $reporter->directory_path();
    $output_dir->mkpath unless ($output_dir->exists);

    die "Unable to create $output_dir" unless $output_dir->exists;

    $output_filepath = $reporter->output_file_path();
    $output_filepath->spew_utf8(@csv);
    $log->debugf('Data file name %s created.', $output_filepath);
}
catch {
    my $error = $@;
    $statsd->event('Affiliate Turnover Report Failed', "TurnoverReporter failed to generate csv files due: $error");
}

try {
    $log->debugf('Sending email for affiliate turnover report');
    $reporter->send_report(
        subject    => 'CRON generate_affiliate_turnover_daily ' . ' for date ' . $processing_date->date_yyyymmdd,
        message    => ['Find attached the CSV that was generated.'],
        attachment => $output_filepath,
    );
}
catch {
    my $error = $@;
    $statsd->event('Affiliate Turnover Report Failed', "TurnoverReporter failed to send the csv files due: $error");
}

1;

#!/etc/rmg/bin/perl
package main;

use Log::Any qw($log);
use Getopt::Long 'GetOptions';

use Brands;

use BOM::MyAffiliates::GenerateRegistrationDaily;
use BOM::Platform::Email qw(send_email);

local $SIG{ALRM} = sub { die "alarm\n" };
alarm 1800;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'b|brand=s' => \my $brand,
    'l|log=s'   => \my $log_level,
);

$log_level ||= 'error';
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

run() unless caller;

sub run {
    my $brand_object = Brands->new(name => $brand);
    my $reporter = BOM::MyAffiliates::GenerateRegistrationDaily->new(
        processing_date => Date::Utility->new(time - 86400),
        brand           => $brand_object
    );

    my $output_dir = $reporter->directory_path();
    $output_dir->mkpath unless $output_dir->exists;

    die "Unable to create $output_dir" unless $output_dir->exists;

    my $output_filepath = $reporter->output_file_path();
    # check if file exist and is not of size 0
    if ($output_filepath->exists and $output_filepath->stat->size > 0) {
        die "There is already a file $output_filepath with size "
            . $output_filepath->stat->size
            . " created at "
            . Date::Utility->new($output_filepath->stat->mtime)->datetime;
    }

    my @csv = $reporter->activity();

    my $output_filepath = $reporter->output_file_path();
    $output_filepath->spew_utf8(@csv);
    $log->debugf('Data file name %s created.', $output_filepath);

    $log->debugf('Sending email for affiliate registration report');
    $reporter->send_report(
        subject    => 'CRON registrations: Report for ' . Date::Utility->new->datetime_yyyymmdd_hhmmss_TZ,
        message    => $reporter->report_output,
        attachment => $output_filepath->stringify,
    );
}

1;

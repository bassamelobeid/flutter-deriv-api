#!/etc/rmg/bin/perl
package main;

use Log::Any qw($log);
use Getopt::Long 'GetOptions';
use DataDog::DogStatsd;
use Archive::Zip qw( :ERROR_CODES );
use Path::Tiny;
use Date::Utility;
use Syntax::Keyword::Try;

use Brands;

use BOM::MyAffiliates::GenerateRegistrationDaily;
use BOM::Platform::Email qw(send_email);

local $SIG{ALRM} = sub { die "alarm\n" };
alarm 1800;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'l|log=s' => \my $log_level,
);

$log_level ||= 'warn';
Log::Any::Adapter->import(
    qw(DERIV),
    stdout    => 'text',
    log_level => $log_level
);

run() unless caller;

sub run {
    my $processing_date = Date::Utility->new(time - 86400);
    my $reporter        = BOM::MyAffiliates::GenerateRegistrationDaily->new(
        processing_date => $processing_date,
        brand           => Brands->new(name => 'binary'));

    my $output_filepath = _get_output_file_path($reporter);

# we generate data only once
# it's the same data for both the brands
# myaffiliates to reflect data properly on their side expects
# all the registration - irrespective of brands
    my @csv = $reporter->activity();

    $output_filepath->spew_utf8(@csv);
    $log->debugf('Data file name %s created.', $output_filepath);

    my $reporter_download_url = _get_download_url(
        reporter        => $reporter,
        output_filepath => $output_filepath
    );

    my $reporter_deriv = BOM::MyAffiliates::GenerateRegistrationDaily->new(
        processing_date => $processing_date,
        brand           => Brands->new(name => 'deriv'));

    my $csv_object = Text::CSV->new;
    my @output     = ();
    foreach my $csv_record (@csv) {
        my $status = $csv_object->parse($csv_record);
        die "Cannot parse $csv_record" unless $status;

        my @columns = $csv_object->fields();
        # add deriv prefix
        # mandatory for myaffiliates to work properly
        $columns[1] = $reporter_deriv->prefix_field($columns[1]);
        $csv_object->combine(@columns);
        push @output, $reporter_deriv->format_data($csv_object->string);
    }

    $output_filepath = _get_output_file_path($reporter_deriv);
    $output_filepath->spew_utf8(@output);
    $log->debugf('Data file name %s created.', $output_filepath);

    my $reporter_deriv_download_url = _get_download_url(
        reporter        => $reporter_deriv,
        output_filepath => $output_filepath
    );

    $log->debugf('Sending email for affiliate registration report');
    $reporter->send_report(
        subject => 'CRON registrations: Report for ' . Date::Utility->new->datetime_yyyymmdd_hhmmss_TZ,
        message => [
                  'Find links to download CSV that was generated in "'
                . join(',', $reporter->headers())
                . '" format'
                . "\n $reporter_download_url \n $reporter_deriv_download_url"
        ],
    );
}

sub _get_output_file_path {
    my $reporter = shift;

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

    return $output_filepath;
}

sub _get_download_url {
    my (%args) = @_;

    my $reporter        = $args{reporter};
    my $output_filepath = $args{output_filepath};

    my $zip = Archive::Zip->new();
    $zip->addFile($output_filepath->stringify, $output_filepath->basename);

    my $output_zip =
        "myaffiliates_" . $reporter->brand->name . '_' . $reporter->output_file_prefix() . $reporter->processing_date->date_yyyymmdd . ".zip";
    my $output_zip_path = path("/tmp")->child($output_zip)->stringify;

    my $statsd = DataDog::DogStatsd->new;
    my @warn_msgs;
    try {
        unless ($zip->numberOfMembers) {
            $statsd->event('Failed to generate MyAffiliates registration report', 'MyAffiliates registration report generated an empty zip archive');
            $log->warnf("Generated empty zip file %s,the related warnings are: \n %s", $output_zip_path, join("\n-", @warn_msgs));
            exit 1;
        }

        unless ($zip->writeToFileNamed($output_zip_path) == AZ_OK) {
            $statsd->event('Failed to generate MyAffiliates registration report', "MyAffiliates registration report failed to generate zip archive");
            $log->warn('Failed to generate MyAffiliates registration report: MyAffiliates registration report failed to generate zip archive');
            exit 1;
        }
    } catch ($error) {
        $statsd->event('Failed to generate MyAffiliates registration report',
            "MyAffiliates registration report failed to generate zip archive with $error");
        $log->warnf("Failed to generate MyAffiliates registration report: MyAffiliates registration report failed to generate zip archive with %s",
            $error);
        exit 1;
    }

    my $download_url = $reporter->download_url(
        output_zip => {
            name => $output_zip,
            path => $output_zip_path
        });

    return $download_url;
}

1;

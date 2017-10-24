use strict;
use warnings;

use Path::Tiny;
use Date::Utility;

use Brands;

use BOM::MyAffiliates::TurnoverReporter;
use BOM::Platform::Email qw/send_email/;

my $reporter        = BOM::MyAffiliates::TurnoverReporter->new();
my $processing_date = Date::Utility->new(time - 86400);

my @csv = $reporter->activity_for_date_as_csv($processing_date->date_ddmmmyy);

exit unless @csv;

my $output_dir = BOM::Platform::Runtime->instance->app_config->system->directory->db . '/myaffiliates/';
Path::Tiny::path($output_dir)->mkpath if (not -d $output_dir);

my $output_filename = $output_dir . 'turnover_' . $processing_date->date_yyyymmdd . '.csv';
my $fh              = FileHandle->new('>' . $output_filename);

print $fh $reporter->get_headers_for_csv . "\n";
foreach my $line (@csv) {
    chomp $line;
    print $fh $line . "\n" if $line;
}

undef $fh;

my $brand = Brands->new();
# email CSV out for reporting purposes
send_email({
    from       => $brand->emails('system'),
    to         => $brand->emails('affiliates'),
    subject    => 'CRON generate_affiliate_turnover_daily ' . ' for date ' . $processing_date->date_yyyymmdd,
    message    => ['Find attached the CSV that was generated.'],
    attachment => $output_filename,
});

1;

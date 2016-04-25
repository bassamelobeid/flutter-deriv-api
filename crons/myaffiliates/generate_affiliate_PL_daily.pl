use strict;
use warnings;

use Getopt::Long;
use Path::Tiny;
use FileHandle;

use Date::Utility;
use BOM::System::Localhost;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::MyAffiliates::ActivityReporter;
use BOM::Platform::Sysinit ();
use BOM::Platform::Runtime;

BOM::Platform::Sysinit::init();

my ($from_date_str, $to_date_str);
my $optres = GetOptions(
    'from=s' => \$from_date_str,
    'to=s'   => \$to_date_str,
);

if (!$optres) {
    print STDERR join(' ',
        'Usage:', $0,
        '[--broker-codes=CR[,MLT[,...]]]',
        '[--clients=CR1234[,MLT4321[,...]]]',
        '[--currencies=USD[,GBP[,...]]]',
        '[--from=2009-12-25]', '[--to=2009-12-31]',);
    exit;
} elsif (($from_date_str and not $to_date_str) or ($to_date_str and not $from_date_str)) {
    print STDERR 'Must give both from and to, if giving any.';
    exit;
}

my $yesterday_yyyymmdd = Date::Utility->new(time - 86400);
#Alway start to regenerate the files from start of the month.
my $from_yyyymmdd = Date::Utility->new('01-' . $yesterday_yyyymmdd->month_as_string . '-' . $yesterday_yyyymmdd->year);

$from_date_str ||= $from_yyyymmdd->date_yyyymmdd;
$to_date_str   ||= $yesterday_yyyymmdd->date_yyyymmdd;

my $from_date = Date::Utility->new($from_date_str);
my $to_date   = Date::Utility->new($to_date_str);

my $reporter        = BOM::Platform::MyAffiliates::ActivityReporter->new();
my $processing_date = Date::Utility->new($from_date->epoch);
my @csv_filenames;

while ($to_date->days_between($processing_date) >= 0) {
    my @csv = $reporter->activity_for_date_as_csv($processing_date->date_ddmmmyy);

    my $output_dir = BOM::Platform::Runtime->instance->app_config->system->directory->db . '/myaffiliates/';
    Path::Tiny::path($output_dir)->mkpath if (not -d $output_dir);
    my $output_filename = $output_dir . 'pl_' . $processing_date->date_yyyymmdd . '.csv';

    my $fh = FileHandle->new('>' . $output_filename);

    # Date, Player, P&L, Deposits, RBTO, IDTO, OTO
    foreach my $line (@csv) {
        chomp $line;
        print $fh $line . "\n" if $line;
    }

    undef $fh;

    push @csv_filenames, $output_filename;

    $processing_date = Date::Utility->new($processing_date->epoch + 86400);
}

# email CSV out for reporting purposes
send_email({
    from    => BOM::Platform::Runtime->instance->app_config->system->email,
    to      => BOM::Platform::Runtime->instance->app_config->marketing->myaffiliates_email,
    subject => 'CRON generate_affiliate_PL_daily: Report from '
        . BOM::System::Localhost::name()
        . ' for date range '
        . $from_date->date_yyyymmdd . ' - '
        . $to_date->date_yyyymmdd,
    message    => ['Find attached the CSV that was generated.'],
    attachment => \@csv_filenames,
});

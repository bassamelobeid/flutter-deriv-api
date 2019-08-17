#!/etc/rmg/bin/perl
use strict;
use warnings;

use Date::Utility;
use BOM::Config;
use BOM::Platform::Email qw(send_email);
use Path::Tiny 'path';

=head2

 This script:
 - creates our daily Return to Player report files

=cut

my $specified_rptDate = $ARGV[0];
my $brand             = BOM::Config->brand();

my $report_recipients  = join(',', 'compliance-alerts@binary.com', 'bill@binary.com');
my $failure_recipients = join(',', 'compliance-alerts@binary.com', 'sysadmin@binary.com');

# If we pass in a date, then we presumably want to use that date as our reference date
# We are actually reporting on the year previous to our reference date.
# So if we pass in NOW(), we will report on yesterday + 364 days further back
# NOW/Today is default
my $rd      = Date::Utility->new($specified_rptDate);
my $rptDate = $rd->date_yyyymmdd;
my $start   = $rd->minus_time_interval('365d');
my $end     = $rd->minus_time_interval('1d');

# Our files will be written out for reference with a name like MX_2018-03-02_20180131_20180301.csv
# where first is the broker code (assigned further down in the SQL) and next is the report date.
# The second date is the start of the actual reporting interval
# and the third date is the close of the reporting interval.
my $filename = join('_',
    $rptDate,
    ($start->year . sprintf('%02d', $start->month) . sprintf('%02d', $start->day_of_month)),
    ($end->year . sprintf('%02d', $end->month) . sprintf('%02d', $end->day_of_month)))
    . '.csv';

# where will they go
my $reports_path = '/reports/RTP';
path("$reports_path/MX")->mkpath;
path("$reports_path/MLT")->mkpath;

# just let PG/psql create the files directly
my $rz = qx(/usr/bin/psql service=collector01 -v ON_ERROR_STOP=1 -X <<SQL
    SET SESSION CHARACTERISTICS as TRANSACTION READ ONLY;
    \\COPY (SELECT * FROM return_to_player_on('mx', '$rptDate', '${\$start->date_yyyymmdd}', '${\$end->date_yyyymmdd}')) TO '$reports_path/MX/MX_$filename' WITH (FORMAT 'csv', DELIMITER ',', HEADER);
    \\COPY (SELECT * FROM return_to_player_on('mlt', '$rptDate', '${\$start->date_yyyymmdd}', '${\$end->date_yyyymmdd}')) TO '$reports_path/MLT/MLT_$filename' WITH (FORMAT 'csv', DELIMITER ',', HEADER);
SQL
);

# that psql call gives a proper result like this
# COPY 4567
# COPY 789
# COPY 0 would be a problem
if ($rz =~ /COPY [1-9]+[0-9]*.*COPY [1-9]+[0-9]*/s) {

    my $message = "Files have been created as: MX/MLT_$filename";

    send_email({
            from       => $brand->emails('support'),
            to         => $report_recipients,
            subject    => "Return to Player reporting - $rptDate",
            message    => [$message],
            attachment => ["$reports_path/MX/MX_$filename", "$reports_path/MLT/MLT_$filename"]});
}

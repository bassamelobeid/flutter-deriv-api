#!/etc/rmg/bin/perl
use strict;
use warnings;

use Date::Utility;
use BOM::Config;
use BOM::Platform::Email qw(send_email);
use BOM::MapFintech;
use Path::Tiny 'path';

=head2

 This script:
 - creates our two daily MFID reporting files for MT5

=cut

my $specified_rptDate = $ARGV[0];
my $brand             = BOM::Config->brand();

my $report_recipients = join(',', 'compliance-alerts@binary.com', 'bill@binary.com', 'x-acc@binary.com');
my $failure_recipients = join(',', 'compliance-alerts@binary.com', 'sysadmin@binary.com');

# If we pass in a date, then we presumably want to report on that date
# Yesterday is default
# MAP Fintech originally specified that the filename should include ddmmyyy_hhmmss of the generation time, but should report on the previous day's activity,
# They subsequently acquiesced to a conventional format of yyyymmdd_hhmmss
# so we won't specify a strict seed for the default, otherwise we'll always have '000000' for the time component
my $rd = Date::Utility->new($specified_rptDate);

my $rptDate  = $specified_rptDate ? $rd->date_yyyymmdd            : $rd->minus_time_interval('1d')->date_yyyymmdd;
my $fileDate = $specified_rptDate ? $rd->plus_time_interval('1d') : $rd;

# our files will be written out for reference
my $fileTail = join('',
    $fileDate->year,
    sprintf('%02d', $fileDate->month),
    sprintf('%02d', $fileDate->day_of_month),
    '_', $fileDate->hour, $fileDate->minute, $fileDate->second);
my $mt5_tradesFN = 'BIE001_MT5_trades_' . $fileTail . '.csv';
my $mt5_usersFN  = 'BIE001_MT5_users_' . $fileTail . '.csv';

# where will they go
my $reports_path = '/reports/Emir/' . $fileDate->year;
path($reports_path)->mkpath;

# just let PG/psql create the files directly
my $rz = qx(/usr/bin/psql service=report -v ON_ERROR_STOP=1 -X <<SQL
    SET SESSION CHARACTERISTICS as TRANSACTION READ ONLY;
    \\COPY (SELECT * FROM mt5.mfid_trades_rpt_mt5('$rptDate')) TO '$reports_path/$mt5_tradesFN' WITH (FORMAT 'csv', DELIMITER ',', FORCE_QUOTE *, HEADER);
    \\COPY (SELECT * FROM mt5.mfid_users_rpt_mt5('$rptDate')) TO '$reports_path/$mt5_usersFN' WITH (FORMAT 'csv', DELIMITER ',', FORCE_QUOTE *, HEADER);
SQL
);

# that psql call gives a proper result like this
# COPY 456
# COPY 7890
# COPY 0 can happen on the weekend for trades, but we will always produce a complete client list
# If there is a connection failure, that will result in something similar to this> psql: definition of service "report" not found
# For errors resulting from the SQL it will be similar to this> ERROR:  column "fob" does not exist
if ($rz !~ /psql:|ERROR:/s) {

    my $upload_status = BOM::MapFintech::upload("$reports_path", [$mt5_tradesFN, $mt5_usersFN]);
    my $message = $upload_status ? "There was a problem uploading files: $upload_status" : 'Files uploaded successfully';
    $message .= "\n\nSee attached.";

    # break this into two emails with a separate attachment each if necessary
    send_email({
            from       => $brand->emails('support'),
            to         => $report_recipients,
            subject    => "Emir reporting - $rptDate",
            message    => [$message],
            attachment => ["$reports_path/$mt5_tradesFN", "$reports_path/$mt5_usersFN"]});
} else {
    send_email({
            from    => 'sysadmin@binary.com',
            to      => $failure_recipients,
            subject => "Emir reporting failure - $rptDate",
            message => ["An unexpected response was received while trying to create the report files today: $rz"]});
}

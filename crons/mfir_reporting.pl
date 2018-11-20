#!/etc/rmg/bin/perl
use strict;
use warnings;

use Date::Utility;
use Brands;
use BOM::Platform::Email qw(send_email);
use BOM::Datatracks;
use Path::Tiny 'path';

=head2

 This script:
 - creates our daily MFIR reporting file
 - transfer it to Datatracks via SFTP
 - also email it to compliance

=cut

my $specified_rptDate = $ARGV[0];
my $brand = Brands->new(name => 'binary');

my $report_recipients = join(',', $brand->emails('compliance'), 'bill@binary.com');
my $failure_recipients = join(',', $brand->emails('compliance'), 'sysadmin@binary.com', 'bill@binary.com');

# If we pass in a date, then we presumably want to report on that date
# Yesterday is default
my $rd = Date::Utility->new($specified_rptDate);

# our files will be written out for reference
my $fileTail = join('', $rd->year, sprintf('%02d', $rd->month), sprintf('%02d', $rd->day_of_month), $rd->hour, $rd->minute, $rd->second);
my $FN = 'BNRY_' . $fileTail . '.csv';

# where will they go under reports/ and create that if it doesn't yet exist
my $reports_path = "/reports/MiFIR/@{[ $rd->year ]}";
path($reports_path)->mkpath;

# now adjust our actual reporting date if we have not specified the same
$rd = $rd->minus_time_interval('1d') unless $specified_rptDate;
my $rptDate = $rd->date_yyyymmdd;

# let psql do our CSV formatting
my $rz = qx(/usr/bin/psql service=collector01 -qX -v ON_ERROR_STOP=1 <<SQL
    SET SESSION CHARACTERISTICS as TRANSACTION READ ONLY;
    \\COPY (SELECT * FROM mfirmfsa_report('$rptDate','$rptDate')) TO STDOUT WITH (FORMAT 'csv', DELIMITER ',', FORCE_QUOTE *);
SQL
);

# On weekends there is usually nothing to report. This is what the results look like.
if ((!$rz) || $rz =~ /^"1","Transaction","new"/) {
    open(my $fh, '>', "$reports_path/$FN") || die "Failed to open report file for writing: $reports_path/$FN";
    print $fh BNRY_header();
    print $fh $rz;
    close $fh;

    my $upload_status = BOM::Datatracks::upload("$reports_path", [$FN]);
    my $message = $upload_status ? "There was a problem uploading the file: $upload_status" : 'File uploaded successfully';
    $message .= "\n\nSee attached.";

    send_email({
            from       => $brand->emails('support'),
            to         => $report_recipients,
            subject    => "MFIR reporting - $rptDate",
            message    => [$message],
            attachment => ["$reports_path/$FN"]});
} else {
    send_email({
            from    => 'sysadmin@binary.com',
            to      => $failure_recipients,
            subject => "MFIR reporting failure - $rptDate",
            message => ["An unexpected empty response was received while trying to create the report files today"]});
}

# Yes, this is terribly verbose for column headers, but they match exactly with the definition document provided and so this makes it simple to compare columns in the spreadsheet to definitions
sub BNRY_header {
    return
        q!"S.No","Identifier","Report Status","TRN","Trading Venue Transaction Identification Code","Executing Entity Identification Code","Investment Firm Covered by Directive 2014/65/EU","Submitting entity identification code","Buyer Id Type","Buyer Id Subtype","Buyer identification code","Country of the Branch for the Buyer","Buyer First Name","Buyer Surname","Buyer Date of Birth","Buyer Decision Maker ID Type","Buyer Decision maker code Sub Type","Buyer Decision Maker Code","Buyer Decision Maker First name","Buyer Decision Maker Sur Name","Buyer Decision Maker Date of Birth","Seller ID Type","Seller ID SubType","Seller Identification code","Country of the Branch for seller","Seller First name","Seller Sur Name","Seller Date of Birth","Seller Decision Maker ID Type","Seller Decision Maker ID Sub Type","Seller Decision Maker Code","Seller Decision Maker First name","Seller Decision Maker Sur Name","Seller Decision Maker Date of Birth","Transmission of order Indicator","Transmitting firm identification code for Buyer","Transmitting firm identification code for Seller","Trading Date & Time","Trading Capacity","Quantity Type","Quantity","Quantity Currency","Derivative Notional increase/ Decrease","Price type","Price","Price Currency","Net Amount","Venue","Country of the branch Membership","Upfront Payment","Upfront Payment currency","Complex trade component ID","Instrument Identification code","Instrument Id Type","Instrument Full Name","Instrument Classification","Notional Currency 1","Notional Currency 2 Type","Notional Currency 2","Price Multiplier","Underlying Instrument Type","Underlying Classification","Underlying Instrument Code","Underlying Index Name","Term of the underlying Index","Option Type","Strike price Type","Strike price","Strike price currency","Option Exercise style","Maturity Date ","Expiry Date","Delivery Type","Investment Decision ID Type","Investment Decision ID Sub Type","Investment Decision within Firm","Country of the branch responsible for the person making the inv","Firm Execution Id Type","Firm Execution Id Sub-type","Execution wihin Firm","Country of the branch supervising the person responsible for th","Waiver Indicator","Short selling Indicator","OTC Post Trade Indicator","Commodity Derivative Indicator","SFT Indicator","Data category","Internal Client Identification Code"
!;

}

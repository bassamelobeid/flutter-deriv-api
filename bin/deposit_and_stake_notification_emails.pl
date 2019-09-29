#!/etc/rmg/bin/perl

=for comment

    This is a replacement for a simple shell script to generate an emailed report to assist Compliance in our CCD obligations to MGA.
    Here are some relevant details:

    MGA: Regulation 9(1) of the PMFLTR provides that CDD measures are to be applied when carrying out transactions amounting to 2,000 EUR or more,
        whether carried out within the context of a business relationship or otherwise...

        As regards the 2,000 EUR threshold, this is to be applied vis-a-vis funds deposited onto an account,
        whether in a single transaction or a number of transactions adding up to the said amount...
    
=cut

use strict;
use warnings;

use BOM::Platform::Email qw(send_email);
use Date::Utility;
use Path::Tiny qw(path);

my $yesterday_date = Date::Utility->today()->minus_time_interval('1d')->date;

foreach my $broker ('MLT') {
    
    # Any database with '03' corresponds to replica
    my $svcdef  = lc($broker) . '03';
    
    my $filename = path($broker . '_deposit_withdrawal_stake_' . $yesterday_date . '.csv');;
    my $content = qx{
        psql service=$svcdef -XH -v ON_ERROR_STOP=1 -P null=N/A <<EOF
        \\COPY (SELECT * FROM reporting.deposit_and_stake_notification()) TO '$filename' (format csv, header, null 'N/A');
EOF
    };

    send_email({
        from                  => 'compliance@regentmarkets.com',
        to                    => 'compliance-alerts@binary.com, bill@binary.com',
        subject               => "$broker Authentication (2K deposit, withdrawal or stake) - $yesterday_date",
        email_content_is_html => 1,
        attachment            => ["$filename"]
    });
    
    path($filename)->remove;
}

#!/etc/rmg/bin/perl

=for comment

    This is a replacement for a simple shell script to generate an emailed report to assist Compliance in our CCD obligations to MGA and UKGC.
    Here are some relevant details:
    
    UKGC: 6.3 ... casino operators must also apply CDD measures in relation to any transaction that amounts to 2,000 EUR or more,
        whether the transaction is executed in a single operation or in several operations which appear to be linked

    MGA: Regulation 9(1) of the PMFLTR provides that CDD measures are to be applied when carrying out transactions amounting to 2,000 EUR or more,
        whether carried out within the context of a business relationship or otherwise...

        As regards the 2,000 EUR threshold, this is to be applied vis-a-vis funds deposited onto an account,
        whether in a single transaction or a number of transactions adding up to the said amount...
    
=cut

use strict;
use warnings;

use BOM::Platform::Email qw(send_email);

foreach my $srv ('MX', 'MLT') {
    my $svcdef  = lc($srv) . '03';
    my $content = qx{
        psql service=$svcdef -XH -v ON_ERROR_STOP=1 -P null=N/A <<EOF
SELECT '$srv' AS "Client-DB";
SELECT 'yesterday'::DATE::TEXT AS "Reporting Day";
SELECT * FROM reporting.deposit_and_stake_notification();
EOF
    };

    send_email({
        from                  => 'compliance@regentmarkets.com',
        to                    => 'compliance-alerts@binary.com, bill@binary.com',
        subject               => "$srv Authentication - 2K deposit, withdrawal or stake",
        message               => [$content],
        email_content_is_html => 1
    });
}

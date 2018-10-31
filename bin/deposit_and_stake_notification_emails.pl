#!/etc/rmg/bin/perl

=for comment

    This is a replacement for a simple shell script to generate an emailed report to assist Compliance in our CCD obligations to MGA and UKGC
    
    More details, including regulation excerpts can be found on this card: https://trello.com/c/Nt3OYPZn/3301-fixdepositandstakenotificationcron
    
    If that no longer exists, Compliance will be more than able to cite the current requirements.

=cut

use strict;
use warnings;

use BOM::Platform::Email qw(send_email);

foreach my $srv ('MX','MLT') {
    my $svcdef = lc($srv) . '03';
    my $content = qx{
        psql service=$svcdef -XH -v ON_ERROR_STOP=1 -P null=N/A <<EOF
SELECT '$srv' AS "Client-DB";
SELECT 'yesterday'::DATE::TEXT AS "Reporting Day";
SELECT * FROM deposit_and_stake_notification();
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

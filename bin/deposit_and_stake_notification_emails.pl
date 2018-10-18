#!/etc/rmg/bin/perl
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

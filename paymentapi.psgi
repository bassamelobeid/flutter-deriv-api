use strict;
use warnings;

use lib qw!/etc/perl
    /home/git/regentmarkets/cpan/local/lib/perl5
    /home/git/regentmarkets/cpan/local/lib/perl5/x86_64-linux-gnu-thread-multi
    /home/git/regentmarkets/bom/lib
    /home/git/regentmarkets/bom-paymentapi/lib
    /home/git/regentmarkets/bom-postgres/lib!;

use Plack::Builder;

use BOM::API::Payment;

my $alog;
if ($ENV{ACCESS_LOG}) {
    open $alog, '>>', $ENV{ACCESS_LOG}
        or die "Cannot open access_log: $!";
    select +(select($alog), $| = 1)[0];
}

builder {
    enable 'AccessLog::Timed' => (
        format => '%h %l %u %t "%r" %>s %b %D',
        logger => sub { local $\; print $alog $_[0] },
    ) if $alog;
    BOM::API::Payment->to_app();
};

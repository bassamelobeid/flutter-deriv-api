use strict;
use warnings;
no indirect;

use Plack::Builder;

use BOM::API::Payment;
use IO::Handle;

use Log::Any::Adapter 'DERIV',
    log_level => 'info',
    stderr    => 'json';

my $alog;
if ($ENV{ACCESS_LOG}) {
    open $alog, '>>', $ENV{ACCESS_LOG}    ## no critic (RequireBriefOpen)
        or die "Cannot open access_log: $!";
    $alog->autoflush(1);
}

builder {
    enable 'AccessLog::Timed' => (
        format => '%h %l %u %t "%r" %>s %b %D',
        logger => sub { local $\; print $alog $_[0] },
    ) if $alog;
    BOM::API::Payment->to_app();
};

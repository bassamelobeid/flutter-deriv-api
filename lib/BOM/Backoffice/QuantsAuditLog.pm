package BOM::Backoffice::QuantsAuditLog;

use strict;
use warnings;

use Encode;
use JSON::MaybeXS;
use Date::Utility;

my $json = JSON::MaybeXS->new;

sub log {    ## no critic (ProhibitBuiltinHomonyms)
    my ($staff, $do, $changes) = @_;

    my $to_log_content = " do=$do Changes:$changes\n";

    my @to_log = (
        timestamp => Date::Utility->new->datetime_iso8601,
        staff     => $staff,
        ip        => $ENV{REMOTE_ADDR} || '',
        log       => $to_log_content,
    );

    open(my $fh, ">>", "/var/log/fixedodds/quants_audit.log");
    print $fh $json->encode(\@to_log);
    print $fh "\n";
    close $fh;

    return;
}

1;


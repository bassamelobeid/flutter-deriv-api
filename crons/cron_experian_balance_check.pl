#!/etc/rmg/bin/perl
#
# script get credit balance from Experian and send an email to compliance, if it is lower, than threshold.
#
# threshold can be specified on command line, or 10000 will be used
#
use strict;
use warnings;

use BOM::Backoffice::ExperianBalance;
use BOM::Platform::Config;
use BOM::Platform::Email qw(send_email);

my $brand = Brands->new(name => 'binary');

my ($used, $limit) = BOM::Backoffice::ExperianBalance::get_balance(BOM::Platform::Config::third_party->{proveid}->{username},
    BOM::Platform::Config::third_party->{proveid}->{password});

my $threshold = shift // 10000;
my $remain = $limit - $used;

if ($remain < $threshold) {
    my $message = <<"EOF";
Experian credits warning:
Limit: $limit
Used: $used

Remain: $remain
Threshold: $threshold

EOF
    send_email({
        from    => $brand->emails('system'),
        to      => $brand->emails('compliance'),
        subject => 'Experian balance going low',
        message => [$message],
    });
}


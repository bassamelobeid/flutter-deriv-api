use strict;
use warnings;

use Test::More;

require BOM::Platform::PaymentNotificationQueue;
use Path::Tiny;
use YAML::XS qw(DumpFile);

my $tmp = Path::Tiny->tempfile;
DumpFile(
    $tmp,
    {
        host => '127.0.0.1',
        port => 26540
    });
local $ENV{BOM_PAYMENT_NOTIFICATION_CONFIG} = $tmp->stringify;
BOM::Platform::PaymentNotificationQueue->reload;

my $start = time;
BOM::Platform::PaymentNotificationQueue->add(
    source     => 'test',
    amount     => 0.00,
    type       => 'deposit',
    amount_usd => 0.00,
    currency   => 'USD',
    loginid    => 'CR123',
);
cmp_ok(time - $start, '<=', 3, 'takes less than 3 seconds');

done_testing;


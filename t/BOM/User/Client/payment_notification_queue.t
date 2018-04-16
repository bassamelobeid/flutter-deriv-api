use strict;
use warnings;

use Test::More;

require BOM::User::Client::PaymentNotificationQueue;
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
BOM::User::Client::PaymentNotificationQueue->reload;

my $start = time;
BOM::User::Client::PaymentNotificationQueue->add(
    source     => 'test',
    amount     => 0.00,
    type       => 'deposit',
    amount_usd => 0.00,
    currency   => 'USD',
    loginid    => 'CR123',
);
cmp_ok(time - $start, '<=', 3, 'takes less than 3 seconds');

done_testing;


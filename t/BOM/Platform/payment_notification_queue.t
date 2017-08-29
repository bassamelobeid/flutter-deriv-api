use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::Warnings qw(warnings);

use Path::Tiny;
use YAML::XS qw(DumpFile);

use BOM::Platform::PaymentNotificationQueue;

subtest 'can instantiate Redis object' => sub {
    isa_ok(my $redis = BOM::Platform::PaymentNotificationQueue->redis, 'Mojo::Redis2');
};

subtest '->add_sync warns but raises no exceptions on bad Redis connection' => sub {
    my $temp = Path::Tiny->tempfile;
    DumpFile($temp, {
        write => {
            host => '127.0.0.1',
            port => '2',
        }
    });
    
    my $start = time;
    local $ENV{BOM_TEST_REDIS_REPLICATED} = $temp->stringify;
    BOM::Platform::PaymentNotificationQueue->disconnect;
    cmp_deeply([ warnings {
        is(exception {
            BOM::Platform::PaymentNotificationQueue->add_sync(
                type       => 'deposit',
                source     => 'test',
                loginid    => 'CR1234',
                amount     => '0.00',
                amount_usd => '0.00',
                currency   => 'USD',
            );
        }, undef, 'no exceptions');
    } ], bag(re('Redis')), 'only one redis warning');
    cmp_ok(time, '<=', $start + 5, 'took less than 5 seconds');
};

done_testing();


use strict;
use warnings;

use Test::More;

use BOM::Platform::Redis;

subtest 'acquire_lock' => sub {
    my $key  = "test_acquire_lock";
    my $lock = BOM::Platform::Redis::acquire_lock($key, 1);
    ok $lock, 'A lock has acquired succssfully';
    my $lock2 = BOM::Platform::Redis::acquire_lock($key, 1);
    ok !$lock2, 'Cannot acquire the lock when has not released yet';
};

subtest 'release_lock' => sub {
    my $key  = "test_release_lock";
    my $lock = BOM::Platform::Redis::acquire_lock($key, 1);
    ok $lock, 'A lock has acquired succssfully';
    ok BOM::Platform::Redis::release_lock($key), 'The lock released successfully';
    my $lock2 = BOM::Platform::Redis::acquire_lock($key, 1);
    ok $lock2, 'Can acquire the lock when has released';
};

done_testing();

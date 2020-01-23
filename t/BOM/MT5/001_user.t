#!perl

use strict;
use warnings;

use Test::More;
use Test::Deep qw(cmp_deeply);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::MT5::User::Async;
use Syntax::Keyword::Try;

my $FAILCOUNT_KEY     = 'system.mt5.connection_fail_count';
my $LOCK_KEY          = 'system.mt5.connection_status';
my $BACKOFF_THRESHOLD = 20;
my $BACKOFF_TTL       = 60;

subtest 'MT5 Timeout logic handle' => sub {
    my $timeout_return = {
        error => 'ConnectionTimeout',
        code  => 'ConnectionTimeout'
    };
    my $blocked_return = {
        error => 'no connection',
        code  => 'NoConnection'
    };
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $details = {};
    my $redis   = BOM::Config::RedisReplicated::redis_mt5_user_write();
    # reset all redis keys.
    $redis->del($FAILCOUNT_KEY);
    $redis->del($LOCK_KEY);
    for my $i (1 .. 24) {
        try {
            # this will produce a fialed response
            BOM::MT5::User::Async::create_user($details)->get;
        }
        catch {
            my $result = $@;
            # We will keep trying to connect for the first 20 calls.
            if ($i <= 20) {
                cmp_deeply($result, $timeout_return, 'Returned timedout connection');

                is $redis->get($FAILCOUNT_KEY), $i,           'Fail counter count is updated';
                is $redis->ttl($FAILCOUNT_KEY), $BACKOFF_TTL, 'Fail counter TTL is updated';
                # After that we will set a failure flag, and block further requests
            } elsif ($i == 21) {
                cmp_deeply($result, $blocked_return, 'Call has been blocked');
                is $redis->get($LOCK_KEY), 1, 'lock has been set';
            } elsif ($i > 21) {
                # further calls will be blocked.
                cmp_deeply($result, $blocked_return, 'Call has been blocked');
            }
        }
    }

    is $redis->get($LOCK_KEY), 1, 'lock has been set';
    try {
        # This call will be blocked.
        BOM::MT5::User::Async::get_user(1000)->get;
        is 1, 0, 'This wont be executed';
    }
    catch {
        my $result = $@;
        cmp_deeply($result, $blocked_return, 'Call has been blocked.');
    }

    # Expire the key. as if a minute has passed.
    $redis->expire($FAILCOUNT_KEY, 0);

    try {
        # This call will be timedout.
        BOM::MT5::User::Async::create_user($details)->get;
        is 1, 0, 'This wont be executed';
    }
    catch {
        my $result = $@;
        cmp_deeply($result, $timeout_return, 'Returned timedout connection');
    }

    # Expire the key. as if a minute has passed.
    $redis->expire($FAILCOUNT_KEY, 0);
    # Do a successful call
    is $redis->get($LOCK_KEY), 1, 'lock has been set';
    my $first_success = BOM::MT5::User::Async::get_user(1000)->get;
    is $first_success->{login}, 1000, 'Return is correct';
    # Flags should be reset.
    is $redis->get($LOCK_KEY), 0, 'lock has been reset';

};

done_testing;

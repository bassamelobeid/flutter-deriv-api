use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::MockTime qw( :all );
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Database::UserDB;
use BOM::Config::Redis;
use BOM::User::PhoneNumberVerification;
use Date::Utility;

my $user;
my $pnv;

subtest 'The PNV object' => sub {
    $user = BOM::User->create(
        email    => 'pnvuser@deriv.com',
        password => 'xyz',
    );

    $pnv = $user->pnv;

    is ref($pnv), 'BOM::User::PhoneNumberVerification', 'Got a PNV';
};

subtest 'Phone Number is Verified' => sub {
    ok !$pnv->verified, 'Phone number is not verified';

    $pnv->update(1);

    ok !$pnv->verified, 'Phone number is (cached as) not verified';

    $user = BOM::User->new(id => $user->id);
    $pnv  = $user->pnv;

    ok $pnv->verified, 'Phone number is verified';

    $pnv->update(0);

    ok $pnv->verified, 'Phone number is (cached as) verified';

    $user = BOM::User->new(id => $user->id);
    $pnv  = $user->pnv;

    ok !$pnv->verified, 'Phone number is not verified';
};

subtest 'Next Attempt' => sub {
    my $time = time;

    set_fixed_time($time);

    my $redis      = BOM::Config::Redis::redis_events_write();
    my $redis_mock = Test::MockModule->new(ref($redis));
    my $ttl;

    $redis_mock->mock(
        'ttl',
        sub {
            return $ttl;
        });

    for (undef, 0, -1, -2) {
        $ttl = $_;

        is $pnv->next_attempt, $time, 'Next attempt is the current time';
    }

    $ttl = 100;
    $redis->set(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $user->id, 1, 'EX', $ttl);

    is $pnv->next_attempt, $time + $ttl, 'Correct next attempt from redis';

    $pnv->update(1);

    $user = BOM::User->new(id => $user->id);
    $pnv  = $user->pnv;

    is $pnv->next_attempt, undef, 'No need for a next attempt when verified';

    restore_time();

    $redis_mock->unmock_all();
};

subtest 'Generate OTP' => sub {
    my $time = time;

    set_fixed_time($time);

    $pnv->update(0);
    $user = BOM::User->new(id => $user->id);
    $pnv  = $user->pnv;

    my $redis = BOM::Config::Redis::redis_events_write();
    $redis->del(+BOM::User::PhoneNumberVerification::PNV_OTP_PREFIX . $user->id);

    my $redis_mock = Test::MockModule->new(ref($redis));
    my $ttl;
    my @set_calls;
    $redis_mock->mock(
        'ttl',
        sub {
            return $ttl;
        });

    $redis_mock->mock(
        'set',
        sub {
            push @set_calls, [$_[3], $_[4]];

            return $redis_mock->original('set')->(@_);
        });

    for (1 .. 6) {
        my $expected_otp = $user->id;
        my $counter      = $_;
        @set_calls = ();

        is $pnv->generate_otp(), $expected_otp, 'Correct OTP';

        is $redis->get(+BOM::User::PhoneNumberVerification::PNV_OTP_PREFIX . $user->id), $expected_otp, 'expected otp';

        cmp_deeply [@set_calls], [['EX', +BOM::User::PhoneNumberVerification::TEN_MINUTES]], 'Expected expiration applied';
    }

    restore_time();

    $redis_mock->unmock_all();

};

subtest 'Increase verify attempts' => sub {
    for (1 .. 6) {
        my $counter = $_;

        is $pnv->increase_verify_attempts(), $counter, 'Correct counter';
    }
};

subtest 'Verify is blocked' => sub {
    my $redis = BOM::Config::Redis::redis_events_write();
    $redis->set(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $user->id, +BOM::User::PhoneNumberVerification::SPAM_TOO_MUCH);

    ok !$pnv->verify_blocked, 'Verification is not blocked';

    $redis->incrby(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $user->id, 1);

    ok $pnv->verify_blocked, 'Verification is blocked';

    $redis->incrby(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $user->id, -1);

    ok !$pnv->verify_blocked, 'Verification is no longer blocked';
};

subtest 'Increase attempts' => sub {
    my $time = time;

    set_fixed_time($time);

    $pnv->update(0);
    $user = BOM::User->new(id => $user->id);
    $pnv  = $user->pnv;

    my $redis = BOM::Config::Redis::redis_events_write();
    $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $user->id);

    my $redis_mock = Test::MockModule->new(ref($redis));
    my $ttl;
    my @set_calls;
    $redis_mock->mock(
        'ttl',
        sub {
            return $ttl;
        });

    $redis_mock->mock(
        'set',
        sub {
            push @set_calls, [$_[3], $_[4]];

            return $redis_mock->original('set')->(@_);
        });

    for (1 .. 6) {
        subtest "counter: $_" => sub {
            my $expected_otp = $user->id;
            my $counter      = $_;
            @set_calls = ();

            is $pnv->increase_attempts(), $counter, 'Correct counter';

            is $redis->get(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $user->id), $counter, 'expected counter';

            $ttl = +BOM::User::PhoneNumberVerification::ONE_HOUR;
            $ttl = +BOM::User::PhoneNumberVerification::ONE_MINUTE if $counter <= +BOM::User::PhoneNumberVerification::SPAM_TOO_MUCH;

            is $pnv->next_attempt, $time + $ttl, 'Correct next attempt from redis';

            cmp_deeply [@set_calls], [['EX', $ttl]], "Expected expiration applied $ttl";
        };
    }

    restore_time();

    $redis_mock->unmock_all();
};

subtest 'Verify the OTP' => sub {
    my $otp = $pnv->generate_otp();

    ok $pnv->verify_otp($otp), 'The OTP is valid';

    ok !$pnv->verify_otp($otp), 'The OTP is no longer valid';

    $otp = $pnv->generate_otp();

    $otp .= 'xyz';

    ok !$pnv->verify_otp($otp), 'The OTP is not valid';

    ok !$pnv->verify_otp(), 'Undefined OTP is always invalid';

    $otp = $pnv->generate_otp();

    ok $pnv->verify_otp($otp), 'The OTP is valid';

    $otp = $pnv->generate_otp();

    my $redis = BOM::Config::Redis::redis_events_write();
    $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $user->id);

    ok !$pnv->verify_otp(), 'Undefined stored OTP is always invalid';
};

subtest 'Clear attempts' => sub {
    my $redis = BOM::Config::Redis::redis_events_write();

    $pnv->increase_attempts();

    ok $redis->exists(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $user->id), 'the attempts are set';

    $pnv->clear_attempts();

    ok !$redis->exists(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $user->id), 'the attempts are no longer set';
};

subtest 'Clear verify attempts' => sub {
    my $redis = BOM::Config::Redis::redis_events_write();

    $pnv->increase_verify_attempts();

    ok $redis->exists(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $user->id), 'the verify attempts are set';

    $pnv->clear_verify_attempts();

    ok !$redis->exists(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $user->id), 'the verify attempts are no longer set';
};

done_testing();

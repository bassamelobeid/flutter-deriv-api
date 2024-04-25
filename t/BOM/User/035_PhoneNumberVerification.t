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
        my $expected_otp = $user->id;
        my $counter      = $_;
        @set_calls = ();

        is $pnv->increase_attempts(), $counter, 'Correct counter';

        is $redis->get(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $user->id), $counter, 'expected counter';

        $ttl = +BOM::User::PhoneNumberVerification::TEN_MINUTES;
        $ttl = +BOM::User::PhoneNumberVerification::ONE_HOUR if $counter > +BOM::User::PhoneNumberVerification::SPAM_TOO_MUCH;

        is $pnv->next_attempt, $time + $ttl, 'Correct next attempt from redis';

        cmp_deeply [@set_calls], [['EX', $ttl]], 'Expected expiration applied';
    }

    restore_time();

    $redis_mock->unmock_all();
};

done_testing();

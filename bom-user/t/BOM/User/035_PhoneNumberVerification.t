use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::MockTime qw( :all );
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Database::UserDB;
use BOM::Config::Redis;
use BOM::User::PhoneNumberVerification;
use BOM::Service;
use Date::Utility;

my $customer;
my $pnv;

subtest 'The PNV object' => sub {
    $customer = BOM::Test::Customer->create({
            email    => BOM::Test::Customer::get_random_email_address(),
            password => 'test_passwd',
        },
        [{
                name        => 'CR',
                broker_code => 'CR'
            },
        ]);

    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    is ref($pnv), 'BOM::User::PhoneNumberVerification', 'Got a PNV';
};

subtest 'Phone Number is Verified' => sub {
    ok !$pnv->verified, 'Phone number is not verified';

    $pnv->update(1);

    ok !$pnv->verified, 'Phone number is (cached as) not verified';

    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    ok $pnv->verified, 'Phone number is verified';

    $pnv->update(0);

    ok $pnv->verified, 'Phone number is (cached as) verified';

    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

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
    $redis->set(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $customer->get_user_id(), 1, 'EX', $ttl);

    is $pnv->next_attempt, $time + $ttl, 'Correct next attempt from redis';

    $pnv->update(1);
    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    is $pnv->next_attempt, undef, 'No need for a next attempt when verified';

    restore_time();

    $redis_mock->unmock_all();
};

subtest 'Next Email Attempt' => sub {
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

    $pnv->update(0);
    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    ok !$pnv->verified, 'Phone number is not verified';

    for (undef, 0, -1, -2) {
        $ttl = $_;

        is $pnv->next_email_attempt, $time, 'Next attempt is the current time';
    }

    $ttl = 100;
    $redis->set(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $customer->get_user_id(), 1, 'EX', $ttl);

    is $pnv->next_email_attempt, $time + $ttl, 'Correct next attempt from redis';

    $pnv->update(1);
    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    is $pnv->next_email_attempt, undef, 'No need for a next attempt when verified';

    restore_time();

    $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $customer->get_user_id());

    $redis_mock->unmock_all();
};

subtest 'Next Verify Attempt' => sub {
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

    $pnv->update(0);
    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());
    $pnv->clear_verify_attempts;
    ok !$pnv->verified, 'Phone number is not verified';

    for (undef, 0, -1, -2) {
        $ttl = $_;

        is $pnv->next_verify_attempt, $time, 'Next attempt is the current time';
    }

    $ttl = 100;
    $redis->set(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $customer->get_user_id(), 1, 'EX', $ttl);

    ok !$pnv->verify_blocked, 'Verification is not blocked';

    is $pnv->next_verify_attempt, $time, 'Correct next attempt from redis';

    $redis->set(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $customer->get_user_id(), 4, 'EX', $ttl);

    ok $pnv->verify_blocked, 'Verification is blocked';

    is $pnv->next_verify_attempt, $time + $ttl, 'Correct next attempt from redis';

    $pnv->update(1);
    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    is $pnv->next_verify_attempt, undef, 'No need for a next attempt when verified';

    restore_time();

    $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $customer->get_user_id());

    $redis_mock->unmock_all();
};

subtest 'Generate OTP' => sub {
    my $time = time;

    set_fixed_time($time);

    $pnv->update(0);

    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    my $redis = BOM::Config::Redis::redis_events_write();
    $redis->del(+BOM::User::PhoneNumberVerification::PNV_OTP_PREFIX . $customer->get_user_id());

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
        my $expected_otp = $customer->get_user_id();
        my $counter      = $_;
        @set_calls = ();

        is $pnv->generate_otp(), $expected_otp, 'Correct OTP';

        is $redis->get(+BOM::User::PhoneNumberVerification::PNV_OTP_PREFIX . $customer->get_user_id()), $expected_otp, 'expected otp';

        cmp_deeply [@set_calls], [['EX', +BOM::User::PhoneNumberVerification::TEN_MINUTES]], 'Expected expiration applied';
    }

    restore_time();

    $redis_mock->unmock_all();

};

subtest 'Increase verify attempts' => sub {
    $pnv->clear_verify_attempts;
    for (1 .. 6) {
        my $counter = $_;

        is $pnv->increase_verify_attempts(), $counter, 'Correct counter';
    }
};

subtest 'Verify is blocked' => sub {
    my $redis = BOM::Config::Redis::redis_events_write();
    $redis->set(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $customer->get_user_id(),
        +BOM::User::PhoneNumberVerification::SPAM_TOO_MUCH);

    ok !$pnv->verify_blocked, 'Verification is not blocked';

    $redis->incrby(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $customer->get_user_id(), 1);

    ok $pnv->verify_blocked, 'Verification is blocked';

    $redis->incrby(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $customer->get_user_id(), -1);

    ok !$pnv->verify_blocked, 'Verification is no longer blocked';
};

subtest 'Increase attempts' => sub {
    my $time = time;

    set_fixed_time($time);

    $pnv->update(0);

    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    my $redis = BOM::Config::Redis::redis_events_write();
    $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $customer->get_user_id());

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
            my $expected_otp = $customer->get_user_id();
            my $counter      = $_;
            @set_calls = ();

            is $pnv->increase_attempts(), $counter, 'Correct counter';

            is $redis->get(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $customer->get_user_id()), $counter, 'expected counter';

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
    $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $customer->get_user_id());

    ok !$pnv->verify_otp(), 'Undefined stored OTP is always invalid';
};

subtest 'Clear attempts' => sub {
    my $redis = BOM::Config::Redis::redis_events_write();

    $pnv->increase_attempts();

    ok $redis->exists(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $customer->get_user_id()), 'the attempts are set';

    $pnv->clear_attempts();

    ok !$redis->exists(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $customer->get_user_id()), 'the attempts are no longer set';
};

subtest 'Clear verify attempts' => sub {
    my $redis = BOM::Config::Redis::redis_events_write();

    $pnv->increase_verify_attempts();

    ok $redis->exists(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $customer->get_user_id()), 'the verify attempts are set';

    $pnv->clear_verify_attempts();

    ok !$redis->exists(+BOM::User::PhoneNumberVerification::PNV_VERIFY_PREFIX . $customer->get_user_id()), 'the verify attempts are no longer set';
};

subtest 'Increase email attempts' => sub {
    my $redis      = BOM::Config::Redis::redis_events_write();
    my $redis_mock = Test::MockModule->new(ref($redis));
    my @set_calls;

    $redis_mock->mock(
        'set',
        sub {
            push @set_calls, [$_[3], $_[4]];

            return $redis_mock->original('set')->(@_);
        });

    ok !$redis->exists(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $customer->get_user_id()), 'no email counter';

    for (1 .. +BOM::User::PhoneNumberVerification::SPAM_TOO_MUCH) {
        @set_calls = ();
        $pnv->increase_email_attempts();

        is $redis->get(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $customer->get_user_id()), $_, 'the counter has increased';

        cmp_deeply [@set_calls], [['EX', '60']], 'Expected TTL applied';
    }

    @set_calls = ();
    $pnv->increase_email_attempts();

    my $i = +BOM::User::PhoneNumberVerification::SPAM_TOO_MUCH + 1;
    is $redis->get(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $customer->get_user_id()), $i, 'the counter has increased';

    cmp_deeply [@set_calls], [['EX', '3600']], 'Expected TTL applied (after spamming too much)';
};

subtest 'Email blocked' => sub {
    my $redis = BOM::Config::Redis::redis_events_write();

    ok $pnv->email_blocked, 'Email is blocked';

    $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $customer->get_user_id());

    ok !$pnv->email_blocked, 'Email is no longer blocked';
};

done_testing();

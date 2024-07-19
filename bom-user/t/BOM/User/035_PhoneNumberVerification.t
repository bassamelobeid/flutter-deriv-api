use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::MockTime qw( :all );
use Test::Deep;
use Test::Warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Database::UserDB;
use BOM::Config::Redis;
use BOM::User::PhoneNumberVerification;
use BOM::Service;
use Date::Utility;
use JSON::MaybeUTF8 qw(encode_json_utf8);

my $customer;
my $pnv;

my $config_mock = Test::MockModule->new('BOM::Config::Services');
$config_mock->mock(
    'config',
    sub {
        return +{
            host => '127.0.0.1',
            port => '9500',
        };
    });

subtest 'The PNV object' => sub {
    $customer = BOM::Test::Customer->create(
        clients => [{
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
    my $redis = $pnv->redis;
    my $count;

    my $http = +{
        status  => 200,
        content => '',
    };

    my $mock_http_tiny = Test::MockModule->new('HTTP::Tiny');
    my $url;
    $mock_http_tiny->mock(
        get => sub {
            (undef, $url) = @_;
            return {
                status  => $http->{status},
                content => $http->{content}};
        });

    $pnv->update(0);

    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    for my $carrier (qw/whatsapp sms/) {
        subtest $carrier => sub {
            subtest 'success: truthy' => sub {
                $count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $count, 0, "Redis counter is at 0";

                $log->clear();
                $url             = undef;
                $http->{status}  = 200;
                $http->{content} = encode_json_utf8({
                    success => 1,
                });

                ok $pnv->generate_otp($carrier, '+5958090934', 'es'), 'Generate OTP succeeded';
                $log->empty_ok('no generated logs');

                my $new_count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $new_count, 1, "Redis counter has increased";

                my $ttl = $redis->ttl(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier);
                ok $ttl > 0, 'Expected some TTL set';

                is $url, "http://127.0.0.1:9500/pnv/challenge/$carrier/%2B5958090934/es", 'escaped url';
            };

            subtest 'success: falsey' => sub {
                $count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $count, 1, "Redis counter is at 1";

                $log->clear();
                $url             = undef;
                $http->{status}  = 200;
                $http->{content} = encode_json_utf8({
                    success => 0,
                });

                ok !$pnv->generate_otp($carrier, '+5958090934', 'en'), 'Generate OTP failed';
                $log->empty_ok('no generated logs');

                my $new_count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $new_count, 1,                                                               "Redis counter is not increased";
                is $url,       "http://127.0.0.1:9500/pnv/challenge/$carrier/%2B5958090934/en", 'escaped url';
            };

            subtest 'success: undef' => sub {
                $count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $count, 1, "Redis counter is at 1";

                $log->clear();
                $url             = undef;
                $http->{status}  = 200;
                $http->{content} = encode_json_utf8({});

                ok !$pnv->generate_otp($carrier, '+5958090934', 'es'), 'Generate OTP failed';
                $log->empty_ok('no generated logs');

                my $new_count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $new_count, 1,                                                               "Redis counter is not increased";
                is $url,       "http://127.0.0.1:9500/pnv/challenge/$carrier/%2B5958090934/es", 'escaped url';
            };

            subtest 'undef raw response' => sub {
                $count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $count, 1, "Redis counter is at 1";

                $log->clear();
                $url             = undef;
                $http->{status}  = 200;
                $http->{content} = undef;

                ok !$pnv->generate_otp($carrier, '+595 8090934', 'es'), 'Generate OTP failed';
                $log->empty_ok('no generated logs');

                my $new_count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $new_count, 1,                                                                  "Redis counter is not increased";
                is $url,       "http://127.0.0.1:9500/pnv/challenge/$carrier/%2B595%208090934/es", 'escaped url';
            };

            subtest 'invalid json   ' => sub {
                $count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $count, 1, "Redis counter is at 1";

                $log->clear();
                $url             = undef;
                $http->{status}  = 200;
                $http->{content} = "{'success':1}";

                ok !$pnv->generate_otp($carrier, '+5958090934', 'es'), 'Generate OTP failed';
                $log->contains_ok(qr/Unable to generate phone number for user/);

                my $new_count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $new_count, 1,                                                               "Redis counter is not increased";
                is $url,       "http://127.0.0.1:9500/pnv/challenge/$carrier/%2B5958090934/es", 'escaped url';
            };

            subtest 'success: truthy (again)' => sub {
                $count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $count, 1, "Redis counter is at 1";

                $log->clear();
                $url             = undef;
                $http->{status}  = 200;
                $http->{content} = encode_json_utf8({
                    success => 1,
                });

                ok $pnv->generate_otp($carrier, '+5958090934', 'es'), 'Generate OTP succeeded';
                $log->empty_ok('no generated logs');

                my $new_count = $redis->get(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . $carrier) // 0;
                is $new_count, 2,                                                               "Redis counter has increased";
                is $url,       "http://127.0.0.1:9500/pnv/challenge/$carrier/%2B5958090934/es", 'escaped url';
            };
        };
    }

    $mock_http_tiny->unmock_all();
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

subtest 'Verify, Taken and Release' => sub {
    ok !$pnv->is_phone_taken('+44555000'), 'Phone number not taken';
    ok !$pnv->is_phone_taken('+22555000'), 'Phone number not taken';
    ok !$pnv->is_phone_taken('44555000'),  'Phone number not taken';
    ok !$pnv->is_phone_taken('22555000'),  'Phone number not taken';
    ok $pnv->verify('+44555000'),          'Phone number verified';
    ok !$pnv->is_phone_taken('+44555000'), 'Phone number not taken';
    ok !$pnv->is_phone_taken('+22555000'), 'Phone number not taken';

    my $customer2 = BOM::Test::Customer->create(
        clients => [{
                name        => 'CR',
                broker_code => 'CR'
            },
        ]);

    my $pnv2 = BOM::User::PhoneNumberVerification->new($customer2->get_user_id(), $customer2->get_user_service_context());

    ok $pnv2->is_phone_taken('+44555000'),    'Phone number taken';
    ok $pnv2->is_phone_taken('44555000'),     'Phone number taken';
    ok $pnv2->is_phone_taken('++44.555.000'), 'Phone number taken';
    ok !$pnv2->is_phone_taken('+22555000'),   'Phone number not taken';

    Test::Warnings::allow_warnings(1);
    $log->clear();
    ok !$pnv2->verify('+44555000'), 'Cannot verify taken number';
    $log->contains_ok(qr/Unable to verify phone number for user/, 'Expected log entry');
    Test::Warnings::allow_warnings(0);

    ok $pnv2->is_phone_taken('+44555000'),  'Phone number taken';
    ok !$pnv2->is_phone_taken('+22555000'), 'Phone number not taken';

    ok $pnv->verify('+4455++50++00'),      'Can re-verify the same phone';
    ok !$pnv->is_phone_taken('+44555000'), 'Phone number not taken';
    ok !$pnv->is_phone_taken('+22555000'), 'Phone number not taken';

    ok $pnv->release(),                     'Released phone number';
    ok !$pnv->is_phone_taken('+44555000'),  'Phone number not taken';
    ok !$pnv->is_phone_taken('+22555000'),  'Phone number not taken';
    ok !$pnv2->is_phone_taken('+44555000'), 'Phone number not taken';
    ok !$pnv2->is_phone_taken('+22555000'), 'Phone number not taken';

    ok $pnv2->verify('+44555000'),          'Can verify the released phone number';
    ok $pnv->is_phone_taken('+44555000'),   'Phone number taken';
    ok !$pnv->is_phone_taken('+22555000'),  'Phone number not taken';
    ok !$pnv2->is_phone_taken('+44555000'), 'Phone number not taken';
    ok !$pnv2->is_phone_taken('+22555000'), 'Phone number not taken';

    ok $pnv->verify('+22555000'),           'Can verify the phone number';
    ok $pnv->is_phone_taken('+44555000'),   'Phone number taken';
    ok !$pnv->is_phone_taken('+22555000'),  'Phone number not taken';
    ok !$pnv2->is_phone_taken('+44555000'), 'Phone number not taken';
    ok $pnv2->is_phone_taken('+22555000'),  'Phone number taken';

    Test::Warnings::allow_warnings(1);
    $log->clear();
    ok !$pnv2->verify('+22555000'), 'Cannot verify the phone number';
    $log->contains_ok(qr/Unable to verify phone number for user/, 'Expected log entry');
    Test::Warnings::allow_warnings(0);

    Test::Warnings::allow_warnings(1);
    $log->clear();
    ok !$pnv->verify('+44555000'), 'Cannot verify the phone number';
    $log->contains_ok(qr/Unable to verify phone number for user/, 'Expected log entry');
    Test::Warnings::allow_warnings(0);
};

subtest 'Verify the OTP' => sub {
    my $http = +{
        status  => 200,
        content => '',
    };

    my $mock_http_tiny = Test::MockModule->new('HTTP::Tiny');
    my $url;
    $mock_http_tiny->mock(
        get => sub {
            (undef, $url) = @_;
            return {
                status  => $http->{status},
                content => $http->{content}};
        });

    $pnv->update(0);
    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    subtest 'success: truthy' => sub {
        $log->clear();
        $url             = undef;
        $http->{status}  = 200;
        $http->{content} = encode_json_utf8({
            success => 1,
        });

        ok $pnv->verify_otp('+5958090934', '12345'), 'Verify OTP succeeded';
        $log->empty_ok('no generated logs');

        is $url, "http://127.0.0.1:9500/pnv/verify/%2B5958090934/12345", 'escaped url';
    };

    subtest 'success: falsey' => sub {
        $log->clear();
        $url             = undef;
        $http->{status}  = 200;
        $http->{content} = encode_json_utf8({
            success => 0,
        });

        ok !$pnv->verify_otp('+595 8090934', '12345'), 'Verify OTP failed';
        $log->empty_ok('no generated logs');

        is $url, "http://127.0.0.1:9500/pnv/verify/%2B595%208090934/12345", 'escaped url';
    };

    subtest 'success: undef' => sub {
        $log->clear();
        $url             = undef;
        $http->{status}  = 200;
        $http->{content} = encode_json_utf8({});

        ok !$pnv->verify_otp('+5958090934', '12345'), 'Verify OTP failed';
        $log->empty_ok('no generated logs');
        is $url, "http://127.0.0.1:9500/pnv/verify/%2B5958090934/12345", 'escaped url';
    };

    subtest 'undef raw response' => sub {
        $log->clear();
        $url             = undef;
        $http->{status}  = 200;
        $http->{content} = undef;

        ok !$pnv->verify_otp('+5958090934', '12345'), 'Verify OTP failed';
        $log->empty_ok('no generated logs');
        is $url, "http://127.0.0.1:9500/pnv/verify/%2B5958090934/12345", 'escaped url';
    };

    subtest 'invalid json   ' => sub {
        $http->{status}  = 200;
        $url             = undef;
        $http->{content} = "{'success':1}";

        ok !$pnv->verify_otp('+5958090934', '12345'), 'Verify OTP failed';
        $log->contains_ok(qr/Unable to verify phone number for user/);
        is $url, "http://127.0.0.1:9500/pnv/verify/%2B5958090934/12345", 'escaped url';
    };

    $mock_http_tiny->unmock_all();
};

subtest 'Clear attempts' => sub {
    my $redis = BOM::Config::Redis::redis_events_write();

    $pnv->increase_attempts();

    $pnv->release();
    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

    ok $redis->exists(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $customer->get_user_id()), 'the attempts are set';

    $pnv->clear_attempts();

    ok !$redis->exists(+BOM::User::PhoneNumberVerification::PNV_NEXT_PREFIX . $customer->get_user_id()), 'the attempts are no longer set';
};

subtest 'Clear verify attempts' => sub {
    my $redis = BOM::Config::Redis::redis_events_write();

    $pnv->increase_verify_attempts();

    $pnv->release();
    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

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

subtest 'Clear Phone' => sub {
    is $pnv->clear_phone('++6633423++324324-2342.00'), '6633423324324234200', 'Expected phone after clean up';
    is $pnv->clear_phone('123-123.00'),                '12312300',            'Expected phone after clean up';
    is $pnv->clear_phone('123456'),                    '123456',              'Expected phone after clean up';
};

subtest 'Suspended carriers' => sub {
    my $app_config = $pnv->app_config;

    my $tests = [{
            title  => 'Functional whatsapp',
            before => sub {
                $app_config->system->suspend->pnv_whatsapp(0),;
            },
            after => sub {
                $app_config->system->suspend->pnv_whatsapp(0),;
            },
            result  => 0,
            carrier => 'whatsapp',
        },
        {
            title  => 'Suspended whatsapp',
            before => sub {
                $app_config->system->suspend->pnv_whatsapp(1),;
            },
            after => sub {
                $app_config->system->suspend->pnv_whatsapp(0),;
            },
            result  => 1,
            carrier => 'whatsapp',
        },
        {
            title  => 'Functional sms',
            before => sub {
                $app_config->system->suspend->pnv_sms(0),;
            },
            after => sub {
                $app_config->system->suspend->pnv_sms(0),;
            },
            result  => 0,
            carrier => 'sms',
        },
        {
            title  => 'Suspended sms',
            before => sub {
                $app_config->system->suspend->pnv_sms(1),;
            },
            after => sub {
                $app_config->system->suspend->pnv_sms(0),;
            },
            result  => 1,
            carrier => 'sms',
        },
        {
            title  => 'Unknown carrier',
            before => sub {
            },
            after => sub {
            },
            result  => 1,
            carrier => 'telegram',
        },
    ];

    for my $test ($tests->@*) {
        my ($title, $before, $after, $result, $carrier) = @{$test}{qw/title before after result carrier/};

        subtest $title => sub {
            $before->();

            is $pnv->is_suspended($carrier), $result, "Expected result for $carrier = $result";

            $after->();
        };
    }
};

subtest 'Depleted carriers' => sub {
    my $redis      = $pnv->redis;
    my $app_config = $pnv->app_config;

    my $tests = [{
            title  => 'Functional whatsapp',
            before => sub {
                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp', 0);
                $app_config->system->phone_number_verification->whatsapp_daily_limit(1),;
            },
            after => sub {
                $app_config->system->phone_number_verification->whatsapp_daily_limit(5000),
                    $redis->del(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp');
            },
            result  => 0,
            carrier => 'whatsapp',
        },
        {
            title  => 'Depleted whatsapp',
            before => sub {
                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp', 1);
                $app_config->system->phone_number_verification->whatsapp_daily_limit(1),;
            },
            after => sub {
                $app_config->system->phone_number_verification->whatsapp_daily_limit(5000),
                    $redis->del(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp');
            },
            result  => 1,
            carrier => 'whatsapp',
        },
        {
            title  => 'Functional sms',
            before => sub {
                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 0);
                $app_config->system->phone_number_verification->sms_daily_limit(1),;
            },
            after => sub {
                $app_config->system->phone_number_verification->sms_daily_limit(5000),
                    $redis->del(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms');
            },
            result  => 0,
            carrier => 'sms',
        },
        {
            title  => 'Depleted sms',
            before => sub {
                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 1);
                $app_config->system->phone_number_verification->sms_daily_limit(1),;
            },
            after => sub {
                $app_config->system->phone_number_verification->sms_daily_limit(5000),
                    $redis->del(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms');
            },
            result  => 1,
            carrier => 'sms',
        },
        {
            title  => 'Unknown carrier',
            before => sub {
            },
            after => sub {
            },
            result  => 1,
            carrier => 'telegram',
        },
    ];

    for my $test ($tests->@*) {
        my ($title, $before, $after, $result, $carrier) = @{$test}{qw/title before after result carrier/};

        subtest $title => sub {
            $before->();

            is $pnv->is_depleted($carrier), $result, "Expected result for $carrier = $result";

            $after->();
        };
    }
};

subtest 'Available carriers' => sub {
    my $redis      = $pnv->redis;
    my $app_config = $pnv->app_config;

    my $tests = [{
            title  => 'PNV shutdown as a whole',
            before => sub {
                $app_config->system->suspend->phone_number_verification(1);
            },
            after => sub {
                $app_config->system->suspend->phone_number_verification(0);
            },
            result => {
                whatsapp => 0,
                sms      => 0,
            },
        },
        {
            title  => 'Functional whatsapp and sms',
            before => sub {
                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp', 0);
                $app_config->system->phone_number_verification->whatsapp_daily_limit(1);
                $app_config->system->suspend->pnv_whatsapp(0);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 0);
                $app_config->system->phone_number_verification->sms_daily_limit(1);
                $app_config->system->suspend->pnv_sms(0);
            },
            after => sub {
                $app_config->system->phone_number_verification->whatsapp_daily_limit(5000),
                    $redis->del(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp');
                $app_config->system->suspend->pnv_whatsapp(0);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 5000);
                $app_config->system->phone_number_verification->sms_daily_limit(1);
                $app_config->system->suspend->pnv_sms(0);
            },
            result => {
                whatsapp => 1,
                sms      => 1,
            },
        },
        {
            title  => 'Whatsapp is suspended',
            before => sub {
                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp', 0);
                $app_config->system->phone_number_verification->whatsapp_daily_limit(1);
                $app_config->system->suspend->pnv_whatsapp(1);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 0);
                $app_config->system->phone_number_verification->sms_daily_limit(1);
                $app_config->system->suspend->pnv_sms(0);
            },
            after => sub {
                $app_config->system->phone_number_verification->whatsapp_daily_limit(5000);
                $redis->del(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp');
                $app_config->system->suspend->pnv_whatsapp(0);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 5000);
                $app_config->system->phone_number_verification->sms_daily_limit(1);
                $app_config->system->suspend->pnv_sms(0);
            },
            result => {
                whatsapp => 0,
                sms      => 1,
            },
        },
        {
            title  => 'Whatsapp is depleted',
            before => sub {
                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp', 1);
                $app_config->system->phone_number_verification->whatsapp_daily_limit(1);
                $app_config->system->suspend->pnv_whatsapp(0);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 0);
                $app_config->system->phone_number_verification->sms_daily_limit(1), $app_config->system->suspend->pnv_sms(0);
            },
            after => sub {
                $app_config->system->phone_number_verification->whatsapp_daily_limit(5000);
                $redis->del(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp');
                $app_config->system->suspend->pnv_whatsapp(0);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 5000);
                $app_config->system->phone_number_verification->sms_daily_limit(1);
                $app_config->system->suspend->pnv_sms(0);
            },
            result => {
                whatsapp => 0,
                sms      => 1,
            },
        },
        {
            title  => 'SMS is suspended',
            before => sub {
                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp', 0);
                $app_config->system->phone_number_verification->whatsapp_daily_limit(1);
                $app_config->system->suspend->pnv_whatsapp(0);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 0);
                $app_config->system->phone_number_verification->sms_daily_limit(1), $app_config->system->suspend->pnv_sms(1);
            },
            after => sub {
                $app_config->system->phone_number_verification->whatsapp_daily_limit(5000);
                $redis->del(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp');
                $app_config->system->suspend->pnv_whatsapp(0);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 5000);
                $app_config->system->phone_number_verification->sms_daily_limit(1);
                $app_config->system->suspend->pnv_sms(0);
            },
            result => {
                whatsapp => 1,
                sms      => 0,
            },
        },
        {
            title  => 'SMS is depleted',
            before => sub {
                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp', 0);
                $app_config->system->phone_number_verification->whatsapp_daily_limit(1);
                $app_config->system->suspend->pnv_whatsapp(0);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 1);
                $app_config->system->phone_number_verification->sms_daily_limit(1);
                $app_config->system->suspend->pnv_sms(0);
            },
            after => sub {
                $app_config->system->phone_number_verification->whatsapp_daily_limit(5000);
                $redis->del(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp');
                $app_config->system->suspend->pnv_whatsapp(0);

                $redis->set(BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 5000);
                $app_config->system->phone_number_verification->sms_daily_limit(1);
                $app_config->system->suspend->pnv_sms(0);
            },
            result => {
                whatsapp => 1,
                sms      => 0,
            },
        },
    ];

    for my $test ($tests->@*) {
        my ($title, $before, $after, $result) = @{$test}{qw/title before after result/};

        subtest $title => sub {
            $before->();

            cmp_deeply $pnv->carriers_availability(), $result, "Expected result for available carriers";

            $after->();
        };
    }
};

$config_mock->unmock_all;

done_testing();

use utf8;
binmode STDOUT, ':utf8';

use strict;
use warnings;

use Test::MockTime;
use Test::More tests => 6;
use Test::Exception;
use Test::Deep qw(cmp_deeply);

use Cache::RedisDB;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::System::Password;

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::System::Password::hashpw($password);

my ($vr_1, $cr_1);
my ($client_vr, $client_cr, $client_cr_new);
lives_ok {
    $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client_vr->email($email);
    $client_vr->save;

    $client_cr->email($email);
    $client_cr->save;

    $vr_1 = $client_vr->loginid;
    $cr_1 = $client_cr->loginid;
}
'creating clients';

my %pass = (password => $password);
my $status;
my $user;

lives_ok {
    $user = BOM::Platform::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->save;

    $user->add_loginid({loginid => $vr_1});
    $user->save;
}
'create user with loginid';

subtest 'test attributes' => sub {
    throws_ok { BOM::Platform::User->new } qr/BOM::Platform::User->new called without args/, 'new without args';
    throws_ok { BOM::Platform::User->new({badkey => 1234}) } qr/no email/, 'new without email';

    is $user->email,    $email,    'email ok';
    is $user->password, $hash_pwd, 'password ok';
};

my @loginids;
my $cr_2;
subtest 'default loginid & cookie' => sub {
    subtest 'only VR acc' => sub {
        @loginids = ($vr_1);
        cmp_deeply(@loginids, (map { $_->loginid } $user->loginid), 'loginid match');

        my $def_client = ($user->clients)[0];
        is $def_client->loginid, $vr_1, 'no real acc, VR as default';

        my $cookie_str = "$vr_1:V:E";
        is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
    };

    subtest 'with real acc' => sub {
        $user->add_loginid({loginid => $cr_1});
        $user->save;

        push @loginids, $cr_1;
        cmp_deeply(sort @loginids, (sort map { $_->loginid } $user->loginid), 'loginids array match');

        my $def_client = ($user->clients)[0];
        is $def_client->loginid, $cr_1, 'real acc as default';

        my $cookie_str = "$cr_1:R:E+$vr_1:V:E";
        is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
    };

    subtest 'add more real acc' => sub {
        $client_cr_new = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client_cr_new->email($email);
        $client_cr_new->save;
        $cr_2 = $client_cr_new->loginid;

        $user->add_loginid({loginid => $cr_2});
        $user->save;

        push @loginids, $cr_2;
        cmp_deeply(sort @loginids, (sort map { $_->loginid } $user->loginid), 'loginids array match');

        my $def_client = ($user->clients)[0];
        is $def_client->loginid, $cr_1, 'still first real acc as default';

        my $cookie_str = "$cr_1:R:E+$cr_2:R:E+$vr_1:V:E";
        is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
    };

    subtest 'with disabled acc' => sub {
        subtest 'disable first real acc' => sub {
            lives_ok {
                $client_cr->set_status('disabled', 'system', 'testing');
                $client_cr->save;
            }
            'disable';

            cmp_deeply(sort @loginids, (sort map { $_->loginid } $user->loginid), 'loginids array match');

            my $def_client = ($user->clients)[0];
            is $def_client->loginid, $cr_2, '2nd real acc as default';

            my $cookie_str = "$cr_1:R:D+$cr_2:R:E+$vr_1:V:E";
            is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
        };

        subtest 'disable second real acc' => sub {
            lives_ok {
                $client_cr_new->set_status('disabled', 'system', 'testing');
                $client_cr_new->save;
            }
            'disable';

            cmp_deeply(sort @loginids, (sort map { $_->loginid } $user->loginid), 'loginids array match');

            my $def_client = ($user->clients)[0];
            is $def_client->loginid, $vr_1, 'VR acc as default';

            my $cookie_str = "$cr_1:R:D+$cr_2:R:D+$vr_1:V:E";
            is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
        };

        subtest 'disable VR acc' => sub {
            lives_ok {
                $client_vr->set_status('disabled', 'system', 'testing');
                $client_vr->save;
            }
            'disable';

            cmp_deeply(sort @loginids, (sort map { $_->loginid } $user->loginid), 'loginids array match');

            my $def_client = ($user->clients)[0];
            is $def_client, undef, 'all acc disabled, no default';

            my $cookie_str = "$cr_1:R:D+$cr_2:R:D+$vr_1:V:D";
            is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
        };
    };
};

subtest 'user / email from loginid not allowed' => sub {
    my $user_2 = BOM::Platform::User->new({
        email => $vr_1,
    });
    isnt($user_2, "BOM::Platform::User", "Cannot create User using loginid");
};

subtest 'User Login' => sub {
    subtest 'cannot login if disabled' => sub {
        $client_vr->set_status('disabled', 'system', 'testing');
        $client_vr->save;
        $status = $user->login(%pass);
        ok !$status->{success}, 'All account disabled, user cannot login';
        ok $status->{error} =~ /account is unavailable/;
    };

    subtest 'wiht self excluded accounts' => sub {
        my ($user3, $vr_3, $cr_3, $cr_31);
        my $new_email = 'test'. rand . '@binary.com';
        lives_ok {
            $vr_3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email => $new_email,
            });
            $cr_3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email => $new_email,
            });
            $cr_31 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email => $new_email,
            });

            $user3 = BOM::Platform::User->create(
                email    => $new_email,
                password => $hash_pwd
            );
            $user3->add_loginid({loginid => $cr_3->loginid});
            $user3->add_loginid({loginid => $cr_31->loginid});
            $user3->save;
        }
        'create user with cr accounts only';

        subtest 'cannot login if he has all self excluded account' => sub {
            my $exclude_until_3 = Date::Utility->new()->plus_time_interval('365d')->date;
            my $exclude_until_31 = Date::Utility->new()->plus_time_interval('300d')->date;
            use Data::Dumper;

            $cr_3->set_exclusion->exclude_until($exclude_until_3);
            $cr_3->save;
            $cr_31->set_exclusion->exclude_until($exclude_until_31);
            $cr_31->save;

            $status = $user3->login(%pass);

            ok $status->{error} =~ /Sorry, you have excluded yourself until $exclude_until_31/, 'It should the earlist until date in message error';
        };

        subtest 'if user has vr account and other accounts is self excluded' => sub {
            $user3->add_loginid({loginid => $vr_3->loginid});
            $user3->save;

            $status = $user3->login(%pass);
            is $status->{success}, 1, 'it should use vr account to login';
        };
    };

    subtest 'can login' => sub {
        $client_vr->clr_status('disabled');
        $client_vr->save;
        $status = $user->login(%pass);
        is $status->{success}, 1, 'login successfully';
    };

    subtest 'Suspend All logins' => sub {
        BOM::Platform::Runtime->instance->app_config->system->suspend->all_logins(1);

        $status = $user->login(%pass);
        ok !$status->{success}, 'All logins suspended, user cannot login';
        ok $status->{error} =~ /Login to this account has been temporarily disabled/;

        BOM::Platform::Runtime->instance->app_config->system->suspend->all_logins(0);
    };

    subtest 'Invalid Password' => sub {
        $status = $user->login(password => 'mRX1E3Mi00oS8LG');
        ok !$status->{success}, 'Bad password; cannot login';
        ok $status->{error} =~ /Incorrect email or password/;
    };

    subtest 'Too Many Failed Logins' => sub {
        my $failed_login = $user->failed_login;
        is $failed_login->fail_count, 1, '1 bad attempt';

        $status = $user->login(%pass);
        ok $status->{success}, 'logged in succesfully, it deletes the failed login count';

        $user->login(password => 'wednesday') for 1 .. 6;
        $failed_login = $user->failed_login;
        is $failed_login->fail_count, 6, 'failed login attempts';

        $status = $user->login(%pass);
        ok !$status->{success}, 'Too many bad login attempts, cannot login';
        ok $status->{error} =~ 'Sorry, you have already had too many unsuccessful', "Correct error for too many wrong attempts";

        $failed_login = $user->failed_login;
        $failed_login->last_attempt(DateTime->now->subtract(days => 1));
        ok $user->login(%pass)->{success}, 'clear failed login attempts; can now login';
    };
};

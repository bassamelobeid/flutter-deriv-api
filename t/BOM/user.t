#!perl

use utf8;
binmode STDOUT, ':utf8';

use strict;
use warnings;

use Test::MockTime;
use Test::More;
use Test::Exception;
use Test::Deep qw(cmp_deeply);
use Test::Warnings qw(warning);
use Test::MockModule;
use Path::Tiny;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;
use BOM::User::Password;
use BOM::MT5::User::Async;

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

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

my %args = (
    password => $password,
    app_id   => '1098'
);
my $status;
my $user;

lives_ok {
    $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    cmp_deeply([], [$user->loginids], 'no loginid at first');
    $user->add_client($client_vr);
}
'create user with loginid';

subtest 'test attributes' => sub {
    throws_ok { BOM::User->create } qr/email and password are mandatory/, 'new without args';
    throws_ok { BOM::User->create(badkey => 1234) } qr/email and password are mandatory/, 'new without email';

    is $user->email,    $email,    'email ok';
    is $user->password, $hash_pwd, 'password ok';
    ok !$user->email_verified, 'email not verified';
};

my @loginids;
my $cr_2;
subtest 'default loginid' => sub {
    subtest 'only VR acc' => sub {
        @loginids = ($vr_1);
        cmp_deeply(\@loginids, [$user->loginids], 'loginid match');

        my $def_client = ($user->clients)[0];
        is $def_client->loginid, $vr_1, 'no real acc, VR as default';
    };

    subtest 'with real acc' => sub {
        $user->add_client($client_cr);
        push @loginids, $cr_1;
        cmp_deeply([sort @loginids], [sort $user->loginids], 'loginids array match');
        $user->add_client($client_cr);
        cmp_deeply([sort @loginids], [sort @{$user->{loginids}}], 'loginids still match even we tried to add same loginid twice');

        my $def_client = ($user->clients)[0];
        is $def_client->loginid, $cr_1, 'real acc as default';
    };

    subtest 'add more real acc' => sub {
        $client_cr_new = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client_cr_new->email($email);
        $client_cr_new->save;
        $cr_2 = $client_cr_new->loginid;

        $user->add_client($client_cr_new);

        push @loginids, $cr_2;
        cmp_deeply([sort @loginids], [sort $user->loginids], 'loginids array match');

        my $def_client = ($user->clients)[0];
        is $def_client->loginid, $cr_1, 'still first real acc as default';
    };

    subtest 'with disabled acc' => sub {
        subtest 'disable first real acc' => sub {
            lives_ok {
                $client_cr->status->set('disabled', 'system', 'testing');
            }
            'disable';

            cmp_deeply([sort @loginids], [sort $user->loginids], 'loginids array match');

            my $def_client = ($user->clients)[0];
            is $def_client->loginid, $cr_2, '2nd real acc as default';
        };

        subtest 'disable second real acc' => sub {
            lives_ok {
                $client_cr_new->status->set('disabled', 'system', 'testing');
            }
            'disable';

            cmp_deeply([sort @loginids], [sort $user->loginids], 'loginids array match');

            my $def_client = ($user->clients)[0];
            is $def_client->loginid, $vr_1, 'VR acc as default';
        };

        subtest 'disable VR acc' => sub {
            lives_ok {
                $client_vr->status->set('disabled', 'system', 'testing');
            }
            'disable';

            cmp_deeply([sort @loginids], [sort $user->loginids], 'loginids array match');

            my $def_client = ($user->clients)[0];
            is $def_client, undef, 'all acc disabled, no default';
        };
    };
};

# test load without password

subtest 'load user by loginid' => sub {
    lives_ok {
        my $user_2 = BOM::User->new(
            loginid => $vr_1,
        );
        is $user_2->id, $user->id, 'found correct user by loginid';
        $user_2 = BOM::User->new(
            loginid => 'does not exist',
        );
        is $user_2, undef, 'looking up non-existent loginid results in undef';
    }
    'survived user lookup by loginid';
};

subtest 'User Login' => sub {
    subtest 'cannot login if missing argument' => sub {
        throws_ok { $status = $user->login(); } qr/requires password argument/;
    };
    subtest 'cannot login if disabled' => sub {
        $client_vr->status->set('disabled', 'system', 'testing');
        $status = $user->login(%args);
        ok !$status->{success}, 'All account disabled, user cannot login';
        ok $status->{error} =~ /account is unavailable/;
    };

    subtest 'with self excluded accounts' => sub {
        my ($user3, $vr_3, $cr_3, $cr_31);
        my $new_email = 'test' . rand . '@binary.com';
        lives_ok {
            $vr_3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $new_email,
            });
            $cr_3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email       => $new_email,
            });
            $cr_31 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email       => $new_email,
            });

            $user3 = BOM::User->create(
                email    => $new_email,
                password => $hash_pwd
            );
            $user3->add_client($cr_3);
            $user3->add_client($cr_31);
        }
        'create user with cr accounts only';

        subtest 'can login if he has all self excluded account' => sub {
            my $exclude_until_3  = Date::Utility->new()->plus_time_interval('365d')->date;
            my $exclude_until_31 = Date::Utility->new()->plus_time_interval('300d')->date;

            $cr_3->set_exclusion->exclude_until($exclude_until_3);
            $cr_3->save;
            $cr_31->set_exclusion->exclude_until($exclude_until_31);
            $cr_31->save;

            $status = $user3->login(%args);

            ok $status->{success}, 'Excluded client can login';
        };

        subtest 'can login if he has all self timeouted account' => sub {
            my $timeout_until_3  = Date::Utility->new()->plus_time_interval('2d');
            my $timeout_until_31 = Date::Utility->new()->plus_time_interval('1d');

            $cr_3->set_exclusion->timeout_until($timeout_until_3->epoch);
            $cr_3->save;
            $cr_31->set_exclusion->timeout_until($timeout_until_31->epoch);
            $cr_31->save;

            $status = $user3->login(%args);

            my $timeout_until_31_date = $timeout_until_31->date;
            ok $status->{success}, 'Timeout until client can login';
        };

        subtest 'if user has vr account and other accounts is self excluded' => sub {
            $user3->add_client($vr_3);

            $status = $user3->login(%args);
            is $status->{success}, 1, 'it should use vr account to login';
        };
    };

    subtest 'can login' => sub {
        $client_vr->status->clear_disabled;
        $status = $user->login(%args);
        is $status->{success}, 1, 'login successfully';
        my $login_history = $user->get_last_successful_login_history();
        is $login_history->{action}, 'login', 'correct login history action';
        is $login_history->{status}, 1,       'correct login history status';
    };

    subtest 'Invalid Password' => sub {
        $status = $user->login(%args, password => 'mRX1E3Mi00oS8LG');
        ok !$status->{success}, 'Bad password; cannot login';
        ok $status->{error} eq 'Incorrect email or password. Please check if you previously logged in via a social network.',
            'correct error message for invalid password';
        my $login_history = $user->get_last_successful_login_history();
        is $login_history->{action}, 'login', 'correct last successful login history action';
        is $login_history->{status}, 1,       'correct last successful login history status';
    };

    subtest 'Too Many Failed Logins' => sub {
        my $failed_login = $user->failed_login;
        is $failed_login->{fail_count}, 1, '1 bad attempt';

        $status = $user->login(%args);
        ok $status->{success}, 'logged in succesfully, it deletes the failed login count';

        $user->login(%args, password => 'wednesday') for 1 .. 6;
        $failed_login = $user->failed_login;
        is $failed_login->{fail_count}, 6, 'failed login attempts';

        $status = $user->login(%args);
        ok !$status->{success}, 'Too many bad login attempts, cannot login';
        ok $status->{error} =~ 'Sorry, you have already had too many unsuccessful', "Correct error for too many wrong attempts";

        $user->dbic->run(
            fixup => sub {
                $_->do(
                    'update users.failed_login set last_attempt = ? where id = ?',           undef,
                    Date::Utility->new->minus_time_interval('1d')->datetime_yyyymmdd_hhmmss, $user->id
                );
            });
        ok $user->login(%args)->{success}, 'clear failed login attempts; can now login';
    };
};

subtest 'login_history' => sub {
    my $login_history = $user->login_history(
        order => 'desc',
        limit => 5
    );
    is(scalar @$login_history, 5, 'login_history limit ok');

    $login_history = $user->login_history;
    is(scalar @$login_history, 12, 'login_history limit ok');

    my $args = {
        action      => 'login',
        environment => 'test environment',
        successful  => 't',
        ip          => '1.2.3.4',
        country     => 'earth',
        app_id      => '1098'
    };

    lives_ok { $user->add_login_history(%$args); } 'add login history';
    $login_history = $user->login_history(order => 'desc');
    is(scalar @$login_history, 13, 'login_history ok');
    my $last_login_history = $user->dbic->run(
        sub {
            $_->selectrow_hashref('select * from users.login_history where binary_user_id = ? order by id desc limit 1', undef, $user->id);
        });
    is($last_login_history->{environment}, $args->{environment}, 'correct record');
};

subtest 'MT5 logins' => sub {
    # Mocked account details
    # This hash shared between two files, and should be kept in-sync to avoid test failures
    #   t/BOM/user.t
    #   t/lib/mock_binary_mt5.pl
    my %DETAILS_REAL = (
        login => '1000',
        group => 'real\something',
    );

    my %DETAILS_DEMO = (
        login => '2000',
        group => 'demo\something',
    );
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

    my $loginid_real = 'MT' . $DETAILS_REAL{login};
    my $loginid_demo = 'MT' . $DETAILS_DEMO{login};

    $user->add_loginid($loginid_real);
    my @mt5_logins = $user->mt5_logins;
    cmp_deeply(\@mt5_logins, [$loginid_real], 'MT5 logins match');

    $user->add_loginid($loginid_demo);
    @mt5_logins = $user->mt5_logins;
    cmp_deeply(\@mt5_logins, [$loginid_real, $loginid_demo], 'MT5 logins match');

    @mt5_logins = $user->mt5_logins('real');
    cmp_deeply(\@mt5_logins, [$loginid_real], 'MT5 logins match');

    @mt5_logins = $user->mt5_logins('demo');
    cmp_deeply(\@mt5_logins, [$loginid_demo], 'MT5 logins match');

    ok $_->loginid !~ /^MT\d+$/, 'should not include MT logins-' . $_->loginid for ($user->clients);
};

subtest 'Champion fx users' => sub {
    my ($email_ch, $client_vrch, $client_ch, $vrch_loginid, $ch_loginid, $user_ch) = ('champion@binary.com');
    lives_ok {
        $client_vrch = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRCH',
        });
        $client_ch = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CH',
        });

        $client_vrch->email($email_ch);
        $client_vrch->save;

        $client_ch->email($email_ch);
        $client_ch->save;

        $vrch_loginid = $client_vrch->loginid;
        like $vrch_loginid, qr/^VRCH/, "Correct virtual loginid";
        $ch_loginid = $client_ch->loginid;
        like $ch_loginid, qr/^CH/, "Correct real loginid";
    }
    'creating clients';

    lives_ok {
        $user_ch = BOM::User->create(
            email    => $email_ch,
            password => $hash_pwd
        );

        $user_ch->add_client($client_vrch);
    }
    'create user with loginid';

    subtest 'test attributes' => sub {
        is $user_ch->{email},    $email_ch, 'email ok';
        is $user_ch->{password}, $hash_pwd, 'password ok';
    };
};

subtest 'GAMSTOP' => sub {
    my ($email_gamstop, $client_vrgamstop, $client_gamstop, $client_gamstop_mx, $vrgamstop_loginid, $gamstop_loginid, $user_gamstop) =
        ('gamstop@binary.com');
    lives_ok {
        $client_vrgamstop = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });
        $client_gamstop = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
        });
        $client_gamstop_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
        });

        $client_vrgamstop->email($email_gamstop);
        $client_vrgamstop->residence('gb');
        $client_vrgamstop->save;

        $client_gamstop->email($email_gamstop);
        $client_gamstop->residence('gb');
        $client_gamstop->save;

        $client_gamstop_mx->email($email_gamstop);
        $client_gamstop_mx->residence('gb');
        $client_gamstop_mx->save;

        $vrgamstop_loginid = $client_vrgamstop->loginid;
        $gamstop_loginid   = $client_gamstop->loginid;
    }
    'creating clients';

    lives_ok {
        $user_gamstop = BOM::User->create(
            email    => $email_gamstop,
            password => $hash_pwd
        );

        $user_gamstop->add_client($client_vrgamstop);
        $user_gamstop->add_client($client_gamstop);
        $user_gamstop->add_client($client_gamstop_mx);
    }
    'create user with loginid';

    my $gamstop_module = Test::MockModule->new('Webservice::GAMSTOP');
    my %params         = (
        exclusion => 'Y',
        date      => Date::Utility->new()->datetime_ddmmmyy_hhmmss_TZ,
        unique_id => '111-222-333'
    );
    my $default_client;
    my $date_plus_one_day = Date::Utility->new->plus_time_interval('1d')->date_yyyymmdd;

    subtest 'GAMSTOP - Y - excluded' => sub {
        $gamstop_module->mock('get_exclusion_for', sub { return Webservice::GAMSTOP::Response->new(%params); });

        ok $user_gamstop->login(%args)->{success}, 'can login';
        is $client_gamstop->get_self_exclusion_until_date, Date::Utility->new(DateTime->now()->add(months => 6)->ymd)->date_yyyymmdd,
            'Based on Y response from GAMSTOP client was self excluded';

        $client_gamstop->set_exclusion->exclude_until(undef);
        $client_gamstop->save;
    };

    subtest 'GAMSTOP - N - not excluded' => sub {
        $params{exclusion} = 'N';
        $gamstop_module->mock('get_exclusion_for', sub { return Webservice::GAMSTOP::Response->new(%params); });

        ok $user_gamstop->login(%args)->{success}, 'can login';
        is $client_gamstop->get_self_exclusion_until_date, undef, 'Based on N response from GAMSTOP client was not self excluded';
    };

    subtest 'GAMSTOP - P - previously excluded but not anymore' => sub {
        $params{exclusion} = 'P';

        $gamstop_module->mock('get_exclusion_for', sub { return Webservice::GAMSTOP::Response->new(%params); });

        ok $user_gamstop->login(%args)->{success}, 'can login';
        is $client_gamstop->get_self_exclusion_until_date, undef, 'Based on N response from GAMSTOP client was not self excluded';
    };
};

subtest 'MirrorBinaryUserId' => sub {
    plan tests => 15;
    use YAML::XS qw/LoadFile/;
    use BOM::User::Script::MirrorBinaryUserId;
    use BOM::User::Client;

    my $cfg            = LoadFile '/etc/rmg/userdb.yml';
    my $pgservice_conf = "/tmp/pgservice.conf.$$";
    my $pgpass_conf    = "/tmp/pgpass.conf.$$";
    my $dbh;
    my $t = $ENV{DB_POSTFIX} // '';
    lives_ok {
        path($pgservice_conf)->append(<<"CONF");
[user01]
host=$cfg->{ip}
port=5436
user=write
dbname=users$t
CONF

        path($pgpass_conf)->append(<<"CONF");
$cfg->{ip}:5436:users$t:write:$cfg->{password}
CONF
        chmod 0400, $pgpass_conf;

        @ENV{qw/PGSERVICEFILE PGPASSFILE/} = ($pgservice_conf, $pgpass_conf);

        $dbh = BOM::User::Script::MirrorBinaryUserId::userdb;
    }
    'setup';

    # at this point we have 9 rows in the queue: 2x VRTC, 4x CR, 2x MT and 1x VRCH
    my $queue = $dbh->selectall_arrayref('SELECT binary_user_id, loginid FROM q.add_loginid');

    is $dbh->selectcol_arrayref('SELECT count(*) FROM q.add_loginid')->[0], 12, 'got expected number of queue entries';

    BOM::User::Script::MirrorBinaryUserId::run_once $dbh;
    is $dbh->selectcol_arrayref('SELECT count(*) FROM q.add_loginid')->[0], 0, 'all queue entries processed';

    for my $el (@$queue) {
        if ($el->[1] =~ /^MT/) {
            ok 1, "survived MT account $el->[1]";
        } else {
            my $client = BOM::User::Client->new({loginid => $el->[1]});
            is $client->binary_user_id, $el->[0], "$el->[1] has binary_user_id $el->[0]";
        }
    }
};

subtest 'clients_for_landing_company' => sub {
    $user = BOM::User->new(
        email => $email,
    );
    my @clients = $user->clients_for_landing_company('svg');
    is(scalar @clients, 2, "one cr account");
    is_deeply([map { $_->landing_company->short } @clients], [('svg') x 2], 'lc correct');
    is_deeply([map { $_->loginid } @clients], [qw/CR10000 CR10001/], "clients are correct");
};

subtest 'test load' => sub {
    $user = BOM::User->new(
        email => $email,
    );
    throws_ok { BOM::User->new(hello => 'world'); } qr/no email nor id or loginid/;
    is_deeply(BOM::User->new(id      => $user->id), $user, 'load from id ok');
    is_deeply(BOM::User->new(loginid => $vr_1),     $user, 'load from loginid ok');
    is(BOM::User->new(id => -1), undef, 'return undefine if the user not exist');
};

subtest 'test update email' => sub {
    my $old_email = $user->email;
    ok(!defined($user->email_consent), 'email consent is not defined');
    my $new_email = $old_email . '.test';
    lives_ok { $user->update_email_fields(email => $new_email, email_consent => 1) } 'do update';
    my $new_user = BOM::User->new(email => $new_email);
    is_deeply($new_user, $user, 'get same object after updated');
    is($user->email,         $new_email, 'email updated');
    is($user->email_consent, 1,          'email_consent was updated');
    lives_ok { $new_user->update_email_fields(email => $old_email, email_consent => 0) } 'update back to old email';
    lives_ok { $user = BOM::User->new(id => $user->id); } 'reload user ok';
    is($user->email,         $old_email, 'old email come back');
    is($user->email_consent, 0,          'email_consent is false now');
};

subtest 'test update totp' => sub {
    my $old_secret_key = $user->secret_key;
    ok(!defined($user->is_totp_enabled), 'is_totp_enabled is not defined');
    ok(!defined($user->secret_key),      'secret_key is not defined');
    my $new_secret_key = 'test';
    lives_ok { $user->update_totp_fields(is_totp_enabled => 1, secret_key => $new_secret_key) } 'do update';
    my $new_user = BOM::User->new(id => $user->id);
    is_deeply($new_user, $user, 'get same object after updated');
    is($user->secret_key, $new_secret_key, 'secret_key updated');
    is($user->is_totp_enabled, 1, 'is_totp_enabled was updated');
    lives_ok { $new_user->update_totp_fields(secret_key => $old_secret_key, is_totp_enabled => 0) } 'update back to old email';
    lives_ok { $user = BOM::User->new(id => $user->id); } 'reload user ok';
    is($user->is_totp_enabled, 0, 'is_totp_enabled is false now');
};

subtest 'test update password' => sub {
    my $old_password = $user->password;
    my $new_password = 'test';
    lives_ok { $user->update_password($new_password) } 'do update';
    my $new_user = BOM::User->new(id => $user->id);
    is_deeply($new_user, $user, 'get same object after updated');
    is($user->password, $new_password, 'password updated');
    lives_ok { $new_user->update_password($old_password) } 'update back to old password';
    lives_ok { $user = BOM::User->new(id => $user->id); } 'reload user ok';
    is($user->password, $old_password, 'password restored now');
};

subtest 'test update social signup' => sub {
    ok(!defined($user->has_social_signup), 'has_social_signup is not defined');
    lives_ok { $user->update_has_social_signup(1) } 'do update';
    my $new_user = BOM::User->new(id => $user->id);
    is_deeply($new_user, $user, 'get same object after updated');
    is($user->has_social_signup, 1, 'has_social_signup updated');
    lives_ok { $new_user->update_has_social_signup(0) } 'update back to old value of has_social_signup';
    lives_ok { $user = BOM::User->new(id => $user->id); } 'reload user ok';
    is($user->has_social_signup, 0, 'has_social_signup is false now');
};

subtest 'is_region_eu' => sub {
    my ($client_vr, $client_mlt, $client_mx, $client_cr);
    lives_ok {
        $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });
        $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
        });
        $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
        });
        $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
    }
    'creating clients';

    $client_vr->residence('cn');
    $client_vr->save;

    is $client_vr->is_region_eu, 0, 'is_region_eu FALSE for virtual cn client';

    $client_vr->residence('gb');
    $client_vr->save;

    is $client_vr->is_region_eu, 1, 'is_region_eu TRUE for virtual gb client';

    is $client_mlt->is_region_eu, 1, 'is_region_eu TRUE for MLT client';
    is $client_mx->is_region_eu,  1, 'is_region_eu TRUE for MX client';
    is $client_mx->is_region_eu,  1, 'is_region_eu FALSE for CR client';

};

done_testing;

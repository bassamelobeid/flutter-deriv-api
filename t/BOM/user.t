#!perl

use utf8;
binmode STDOUT, ':utf8';

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Warnings qw(warning);
use Test::MockModule;
use Path::Tiny;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Utility qw(random_email_address);
use BOM::User;
use BOM::User::Password;
use BOM::MT5::User::Async;
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Helper::Client qw(create_client);
use BOM::Test::Script::DevExperts;
use BOM::Test::Helper::CTrader;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use BOM::Rules::Engine;
use BOM::Config;

BOM::Test::Helper::CTrader::mock_server();

my $oauth = BOM::Database::Model::OAuth->new;

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

sub create_apps {
    my $user_id = shift;

    my @app_ids;
    for (0 .. 2) {
        my $app = $oauth->create_app({
            name         => "Test App$_",
            user_id      => $user_id,
            scopes       => ['read', 'trade', 'admin'],
            redirect_uri => "https://www.example$_.com/"
        });

        push @app_ids, $app->{app_id};
    }

    return @app_ids;
}

sub create_tokens {
    my ($user, $client, $app_ids, $ua_fingerprint) = @_;

    $oauth->store_access_token_only(1, $client->loginid, $ua_fingerprint);

    foreach (@$app_ids) {
        $oauth->generate_refresh_token($user->id, $_, 29, 60 * 60 * 24);
    }
}

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
        cmp_deeply([sort @loginids], [sort $user->loginids], 'loginids still match even we tried to add same loginid twice');

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

        $client_cr->account('BTC');
        $client_cr_new->account('USD');
        $def_client = ($user->clients)[0];
        is $def_client->loginid, $cr_2, 'now the second real acc is default because it is fiat';
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

subtest 'user clients' => sub {
    my $user = BOM::User->create(
        email    => random_email_address({domain => 'abc.com'}),
        password => $hash_pwd,
    );

    my %clients =
        map { $_ => BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => $_ eq 'virtual' ? 'VRTC' : 'CR', email => $email}) }
        qw(
        disabled
        self_closed
        enabled
        );

    $user->add_client($clients{$_}) for keys %clients;

    $clients{disabled}->status->set('disabled', 'system', 'test');
    $clients{self_closed}->status->set('closed',   'system', 'test');
    $clients{self_closed}->status->set('disabled', 'system', 'test');

    my @clients = $user->clients;
    is scalar @clients,      1,                          'Only one enabled account';
    is $clients[0]->loginid, $clients{enabled}->loginid, 'correct enabled client loginid';

    @clients = $user->clients(include_disabled => 1);
    is scalar @clients,      3,                          'All clients are returned';
    is $clients[0]->loginid, $clients{enabled}->loginid, 'enabled client is placed at the begining of the list';

    @clients = $user->clients(include_self_closed => 1);
    is scalar @clients,      2,                              'Two clients are returned';
    is $clients[0]->loginid, $clients{enabled}->loginid,     'enabled client is placed at the begining of the list';
    is $clients[1]->loginid, $clients{self_closed}->loginid, 'correct  self-closed loginid';
};

subtest 'accounts_by_category' => sub {
    my $user_by_category = BOM::User->create(
        email    => random_email_address({domain => 'binary.com'}),
        password => $hash_pwd,
    );

    my %clients =
        map { $_ => BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => $_ eq 'virtual' ? 'VRTC' : 'CR', email => $email}) }
        qw(
        virtual
        crypto
        fiat
        disabled
        duplicated
        self_excluded
        );

    $user_by_category->add_client($clients{$_}) for keys %clients;

    $clients{crypto}->account('BTC');
    $clients{fiat}->account('USD');
    $clients{disabled}->status->set('disabled', 'system', 'testing');
    $clients{duplicated}->status->set('duplicate_account', 'system', 'testing');
    $clients{self_excluded}->set_exclusion->exclude_until(Date::Utility->new()->plus_time_interval('365d')->date);
    $clients{self_excluded}->save;

    my $accounts = $user_by_category->accounts_by_category([$user_by_category->bom_loginids], include_duplicated => 1);

    # Use loginids for comparison
    my (%expected_loginids, %categorised_loginids);
    for my $type (sort keys $accounts->%*) {
        $categorised_loginids{$type} = [map { $_->loginid } $accounts->{$type}->@*];
        $expected_loginids{$type}    = [
            $type eq 'enabled'
            ? ($clients{fiat}->loginid, $clients{crypto}->loginid)
            : $clients{$type}->loginid
        ];
    }

    cmp_deeply(\%categorised_loginids, \%expected_loginids, 'all accounts categorised correctly');

    $accounts = $user_by_category->accounts_by_category([$user_by_category->bom_loginids]);
    is scalar $accounts->{duplicated}->@*, 0, 'duplicated list is empty when its param is not true';
};

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
        $client_vr->status->setnx('disabled', 'system', 'testing');
        $status = $user->login(%args);
        ok !$status->{success}, 'All account disabled, user cannot login';
        my $error_message = BOM::User::Static::CONFIG->{errors}->{AccountUnavailable};
        ok $status->{error} =~ /$error_message/, 'Correct error message';
    };

    subtest 'can login if self-closed' => sub {
        my $login_count = scalar $user->login_history(order => 'desc')->@*;

        $client_vr->status->setnx('closed', 'system', 'testing');
        is $user->clients(include_self_closed => 1), 1, 'There is only one client';
        is_deeply $user->login(%args),
            {
            'error'      => 'Your account is deactivated. Please contact us via live chat.',
            'error_code' => 'AccountSelfClosed'
            },
            'Correct  error for eslf-closed accounts';

        is scalar scalar $user->login_history(order => 'desc')->@*, $login_count + 1, 'self-closed login is saved in history';
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
        ok $status->{error} eq 'Your email and/or password is incorrect. Perhaps you signed up with a social account?',
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
        ok !$status->{success},                                                     'Too many bad login attempts, cannot login';
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
    is(scalar @$login_history, 13, 'login_history limit ok');

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
    is(scalar @$login_history, 14, 'login_history ok');
    my $last_login_history = $user->dbic->run(
        sub {
            $_->selectrow_hashref('select * from users.login_history where binary_user_id = ? order by id desc limit 1', undef, $user->id);
        });
    is($last_login_history->{environment}, $args->{environment}, 'correct record');
};

subtest 'MT5 logins' => sub {
    my $mock_server_number = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_server_number->mock('get_trading_server_key', sub { 'p01_ts01' });

    # Mocked account details
    # This hash shared between two files, and should be kept in-sync to avoid test failures
    #   t/BOM/user.t
    #   t/lib/mock_binary_mt5.pl
    my %DETAILS_REAL = (
        login => 'MTR1000',
        group => 'real\something',
    );

    my %DETAILS_DEMO = (
        login => 'MTD2000',
        group => 'demo\something',
    );
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

    my $loginid_real = $DETAILS_REAL{login};
    my $loginid_demo = $DETAILS_DEMO{login};

    $user->add_loginid($loginid_real, 'mt5');
    my @mt5_logins = $user->mt5_logins;
    cmp_deeply(\@mt5_logins, [$loginid_real], 'MT5 logins match');

    $user->add_loginid($loginid_demo, 'mt5');
    @mt5_logins = $user->mt5_logins;
    cmp_deeply(\@mt5_logins, [$loginid_demo, $loginid_real], 'MT5 logins match');

    @mt5_logins = $user->mt5_logins('real');
    cmp_deeply(\@mt5_logins, [$loginid_real], 'MT5 logins match');

    @mt5_logins = $user->mt5_logins('demo');
    cmp_deeply(\@mt5_logins, [$loginid_demo], 'MT5 logins match');

    ok $_->loginid !~ /^MT[DR]?\d+$/, 'should not include MT logins-' . $_->loginid for ($user->clients);
};

subtest 'MirrorBinaryUserId' => sub {
    use YAML::XS qw/LoadFile/;
    use BOM::User::Script::MirrorBinaryUserId;
    use BOM::User::Client;

    my $dbh;
    lives_ok {
        $dbh = BOM::User::Script::MirrorBinaryUserId::userdb;
    }
    'setup';

    # at this point we have 8 rows in the queue: 2x VRTC, 7x CR, 2x MT
    my $queue = $dbh->selectall_arrayref('SELECT binary_user_id, loginid FROM q.add_loginid');
    # dependent on clients created by previous tests
    is $dbh->selectcol_arrayref('SELECT count(*) FROM q.add_loginid')->[0], 17, 'got expected number of queue entries';

    BOM::User::Script::MirrorBinaryUserId::run_once $dbh;
    is $dbh->selectcol_arrayref('SELECT count(*) FROM q.add_loginid')->[0], 0, 'all queue entries processed';

    for my $el (@$queue) {
        if ($el->[1] =~ /^MT[DR]?/) {
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
    cmp_deeply([map { $_->loginid } @clients], bag(qw/CR10000 CR10001/), "clients are correct");
};

# test load without password
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
    ok(!defined($user->is_totp_enabled), 'is_totp_enabled is not defined');
    ok(!defined($user->secret_key),      'secret_key is not defined');

    my @app_ids = create_apps($user->id);

    subtest 'enable 2FA' => sub {
        my $new_secret_key = 'test enable';
        my $ua_fingerprint = 'a1-test_finger_print';
        create_tokens($user, $client_vr, \@app_ids, $ua_fingerprint);

        ok $oauth->has_other_login_sessions($client_vr->loginid), 'There are open login sessions';
        my $refresh_tokens = $oauth->get_refresh_tokens_by_user_id($user->id);
        is scalar $refresh_tokens->@*, scalar @app_ids, 'refresh tokens have been generated correctly';

        # tokens are revoked when 2FA is enabled
        lives_ok { $user->update_totp_fields(is_totp_enabled => 1, secret_key => $new_secret_key, ua_fingerprint => $ua_fingerprint) } 'do update';
        is($user->secret_key,      $new_secret_key, 'secret_key updated');
        is($user->is_totp_enabled, 1,               'is_totp_enabled was updated');
        ok $oauth->has_other_login_sessions($client_vr->loginid), 'Login sessions are revoked';
        is scalar $oauth->get_refresh_tokens_by_user_id($user->id)->@*, 0, 'refresh tokens have been revoked correctly';

        create_tokens($user, $client_vr, \@app_ids, $ua_fingerprint);

        # secret key is not updated if enable again - tokens are not revoked
        lives_ok { $user->update_totp_fields(is_totp_enabled => 1, secret_key => 'xyz', ua_fingerprint => $ua_fingerprint) } 'do reenable and update';
        is($user->secret_key, $new_secret_key, 'secret_key is not changed becuase 2FA was already enabled');
        ok $oauth->has_other_login_sessions($client_vr->loginid), 'Login sessions are not revoked';
        ok $oauth->get_refresh_tokens_by_user_id($user->id)->@*,  'refresh tokens are not revoked';

        lives_ok { $user->update_totp_fields(secret_key => 'xyz') } 'update  secret key when 2FA is enabled';
        is($user->secret_key, $new_secret_key, 'secret_key is not changed becuase 2FA was enabled');
        ok $oauth->has_other_login_sessions($client_vr->loginid), 'Login sessions are not revoked';
        ok $oauth->get_refresh_tokens_by_user_id($user->id)->@*,  'refresh tokens are not revoked';
    };

    subtest 'disable 2FA' => sub {
        my $new_secret_key = 'test disable';
        create_tokens($user, $client_vr, \@app_ids);

        # tokens are revoked when 2FA is enabled
        lives_ok { $user->update_totp_fields(is_totp_enabled => 0, secret_key => $new_secret_key) } 'disable and set secret at the same time';
        is($user->secret_key,      $new_secret_key, 'secret_key updated');
        is($user->is_totp_enabled, 0,               'is_totp_enabled was updated');
        ok $oauth->has_other_login_sessions($client_vr->loginid), 'Login sessions are revoked';
        is scalar $oauth->get_refresh_tokens_by_user_id($user->id)->@*, 0, 'refresh tokens have been revoked correctly';

        create_tokens($user, $client_vr, \@app_ids);

        # secret key is not updated if enable again - tokens are not revoked
        lives_ok { $user->update_totp_fields(is_totp_enabled => 0, secret_key => 'xyz') } 'do reenable and update';
        is($user->secret_key, 'xyz', 'secret_key is changed becuase 2FA was disabled');
        ok $oauth->has_other_login_sessions($client_vr->loginid), 'Login sessions are not revoked';
        ok $oauth->get_refresh_tokens_by_user_id($user->id)->@*,  'refresh tokens are not revoked';

        lives_ok { $user->update_totp_fields(secret_key => $new_secret_key) } 'update  secret key when 2FA is enabled';
        is($user->secret_key, $new_secret_key, 'secret_key changed becuase 2FA was disabled');
        ok $oauth->has_other_login_sessions($client_vr->loginid), 'Login sessions are not revoked';
        ok $oauth->get_refresh_tokens_by_user_id($user->id)->@*,  'refresh tokens are not revoked';
    };

    $oauth->revoke_tokens_by_loginid($_->loginid) for ($user->clients);
    $oauth->revoke_refresh_tokens_by_user_id($user->id);
};

subtest 'test update password' => sub {
    my $old_password = $user->password;
    my $new_password = 'test';
    lives_ok { $user->update_password($new_password) } 'do update';
    my $new_user = BOM::User->new(id => $user->id);
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

subtest 'test update preferred language' => sub {
    ok(!defined($user->preferred_language), 'preferred language is not defined');
    lives_ok { $user->setnx_preferred_language('EN'); } 'set preferred language if not exists works without error';
    is $user->preferred_language, 'EN', 'preferred language set correctly';
    lives_ok { $user->setnx_preferred_language('FA'); } 'set preferred language if not exists called without error';
    is $user->preferred_language, 'EN', 'preferred language didn\'t change since it was set before';

    my $new_user = BOM::User->new(id => $user->id);
    is_deeply($new_user, $user, 'get same object after updated');

    lives_ok { $user->update_preferred_language('ZH_CN'); } 'do update';
    is $user->preferred_language, 'ZH_CN', 'preferred language updated correctly';

    lives_ok { $user->update_preferred_language('fa'); } 'do update';
    is $user->preferred_language, 'FA', 'preferred language updated correctly';

    local $SIG{__WARN__} = sub { };

    throws_ok { $user->update_preferred_language(''); } qr/violates check constraint/, 'updating with undef value got DB error';
    is $user->preferred_language, 'FA', 'preferred language is still same FA correctly';

    throws_ok { $user->update_preferred_language('a'); } qr/violates check constraint/, 'updating with single character value got DB error';
    is $user->preferred_language, 'FA', 'preferred language is still same FA correctly';

    throws_ok { $user->update_preferred_language('AS '); } qr/violates check constraint/, 'updating with "AS " value got DB error';
    is $user->preferred_language, 'FA', 'preferred language is still same FA correctly';

    throws_ok { $user->update_preferred_language('AD_SDD'); } qr/violates check constraint/, 'updating with "AD_SDD" value got DB error';
    is $user->preferred_language, 'FA', 'preferred language is still same FA correctly';

    throws_ok { $user->update_preferred_language('ZH-CN'); } qr/violates check constraint/, 'updating with "ZH-CN" value got DB error';
    is $user->preferred_language, 'FA', 'preferred language is still same FA correctly';

    $new_user = BOM::User->new(id => $user->id);
    is_deeply($new_user, $user, 'get same object after updated');
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

subtest 'fail if mt5 api return empty login' => sub {
    my $mock = Test::MockModule->new('BOM::MT5::User::Async');
    $mock->mock('_invoke_mt5', sub { Future->done({login => ''}) });
    my $f = BOM::MT5::User::Async::create_user({
        mainPassword   => 'password',
        investPassword => 'password',
        agent          => undef,
        group          => 'real/something'
    });
    like($f->failure, qr/Empty login returned/, 'MT5 create_user failed, no/empty login returned');
    $mock->unmock_all;
};

subtest 'test get_financial_assessment' => sub {
    my $client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });
    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });

    ok !$client_mx->get_financial_assessment,  'No financial assessment for client MX';
    ok !$client_mlt->get_financial_assessment, 'No financial assessment for client MLT';

    ok !$client_mx->get_financial_assessment('jibbabi'),     'No financial assessment for client MX';
    ok !$client_mlt->get_financial_assessment('net_income'), 'No financial assessment for client MLT';

    my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
    $client_mx->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8($data)});
    $client_mx->save;

    $client_mlt->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8($data)});
    $client_mlt->save;

    ok $client_mx->get_financial_assessment,  'Financial assessment for client MX exists (returned whole object)';
    ok $client_mlt->get_financial_assessment, 'Financial assessment for client MLT exists (returned whole object)';

    ok !$client_mx->get_financial_assessment('jibbabi'),    'Field does not exist for financial assessment for client MX';
    ok $client_mlt->get_financial_assessment('net_income'), 'Field exists for financial assessment for client MLT';

};

subtest 'create_client' => sub {
    my $wallet_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRW',
    });
    is $wallet_client_vr->is_wallet,    1,         'is wallet client instance';
    is $wallet_client_vr->is_affiliate, 0,         'is wallet client instance';
    is $wallet_client_vr->account_type, 'virtual', 'Correct accouont type';

    my $trading_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    is $trading_client_vr->is_wallet,    0,        'is trading client instance';
    is $trading_client_vr->is_affiliate, 0,        'is trading client instance';
    is $trading_client_vr->account_type, 'binary', 'Correct accouont type';
};

my $wallet;
subtest 'get_wallet_by_loginid' => sub {
    $wallet = create_client('VRW');
    $wallet->set_default_account('USD');
    $wallet->deposit_virtual_funds('10000');

    $client_vr->set_default_account('USD');
    $user->add_client($wallet);

    ok $user->get_wallet_by_loginid($wallet->{loginid}), 'can find wallet account';

    throws_ok { $user->get_wallet_by_loginid('DW1002') } qr/InvalidWalletAccount/, 'invalid wallet account';
};

my ($dxtrade_account, $dxtrader, $ctrader_demo_loginid, $ctrader);
subtest 'get_account_by_loginid' => sub {
    $client_cr_new->status->clear_disabled;
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(0);
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);
    BOM::Config::Runtime->instance->app_config->system->dxtrade->enable_all_market_type->demo(1);
    # try default account (binary/deriv)
    ok $user->get_account_by_loginid($client_vr->{loginid}), 'can find trading account';

    # try wallet account
    throws_ok { $user->get_account_by_loginid('DW1002') } qr/InvalidTradingAccount/, 'invalid account';

    # try mt5 account
    ok $user->get_account_by_loginid('MTD2000'), 'can find mt5 demo account';

    throws_ok { $user->get_account_by_loginid('MTD2001') } qr/InvalidTradingAccount/, 'invalid mt5 account';

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    # try dxtrade account
    throws_ok { $user->get_account_by_loginid('DXR2000') } qr/InvalidTradingAccount/, 'invalid dxtrade account';

    $dxtrader = BOM::TradingPlatform->new(
        platform    => 'dxtrade',
        client      => $client_cr_new,
        user        => $user,
        rule_engine => BOM::Rules::Engine->new(client => $client_cr_new),
    );
    isa_ok($dxtrader, 'BOM::TradingPlatform::DXTrader');

    $dxtrade_account = $dxtrader->new_account(
        account_type => 'demo',
        password     => 'test',
        market_type  => 'all',
        currency     => 'USD',
    );

    my $dxtrade_loginid = $dxtrade_account->{account_id};
    delete $user->{loginid_details};
    is $user->get_account_by_loginid($dxtrade_loginid)->{account_id}, $dxtrade_loginid, 'can find dxtrade demo account';

    # ctrader
    throws_ok { $user->get_account_by_loginid('CTD2000') } qr/InvalidTradingAccount/, 'invalid ctrader account';

    $ctrader = BOM::TradingPlatform->new(
        platform    => 'ctrader',
        client      => $client_cr_new,
        user        => $user,
        rule_engine => BOM::Rules::Engine->new(client => $client_cr_new),
    );

    $ctrader_demo_loginid = $ctrader->new_account(
        account_type => 'demo',
        ,
        market_type => 'all',
        currency    => 'USD',
    )->{account_id};

    is $user->get_account_by_loginid($ctrader_demo_loginid)->{account_id}, $ctrader_demo_loginid, 'can find ctrader demo account';
};

subtest 'link_wallet' => sub {
    $client_cr_new->status->clear_disabled;
    $client_vr->status->clear_disabled;
    delete $user->{loginid_details};

    my $args = {
        wallet_id => $wallet->loginid,
        client_id => $client_vr->loginid
    };
    BOM::Config::Runtime->instance->app_config->system->dxtrade->enable_all_market_type->real(0);
    # try virtual client <-> virtual wallet
    ok $user->link_wallet_to_trading_account($args), 'can bind virtual wallet to a virtual trading account';

    # try demo mt5 <-> virtual wallet
    $args->{wallet_id} = $wallet->loginid;
    $args->{client_id} = 'MTD2000';
    ok $user->link_wallet_to_trading_account($args), 'can bind virtual wallet to a demo mt5 account';

    # try demo dxtrade <-> virtual wallet
    $args->{wallet_id} = $wallet->loginid;
    $args->{client_id} = $dxtrade_account->{account_id};
    ok $user->link_wallet_to_trading_account($args), 'can bind virtual wallet to a demo dxtrade account';

    # try demo ctrader <-> virtual wallet
    $args->{wallet_id} = $wallet->loginid;
    $args->{client_id} = $ctrader_demo_loginid;
    ok $user->link_wallet_to_trading_account($args), 'can bind virtual wallet to a demo ctrader account';

    my $wallet_2 = create_client('VRW');
    $wallet_2->set_default_account('USD');
    $user->add_client($wallet_2);

    $args->{wallet_id} = $wallet_2->loginid;
    $args->{client_id} = $client_vr->loginid;
    throws_ok { $user->link_wallet_to_trading_account($args); } qr/CannotChangeWallet/, 'cannot change to another wallet';

    my $client_cr = create_client('CR');
    $client_cr->set_default_account('USD');
    $user->add_client($client_cr);

    $args->{wallet_id} = $wallet->loginid;
    $args->{client_id} = $client_cr->loginid;
    throws_ok { $user->link_wallet_to_trading_account($args); } qr/CannotLinkVirtualAndReal/, 'cannot bind virtual wallet to a real trading account';

    $args->{wallet_id} = $wallet->loginid;
    $args->{client_id} = 'MTR1000';
    throws_ok { $user->link_wallet_to_trading_account($args); } qr/CannotLinkVirtualAndReal/, 'cannot bind virtual wallet to a real mt5 account';

    my $dxtrade_real_account = $dxtrader->new_account(
        account_type => 'real',
        password     => 'test',
        market_type  => 'all',
        currency     => 'USD',
    );
    $wallet->user->add_loginid($dxtrade_real_account->{account_id}, 'dxtrade', 'real', 'USD', {});
    delete $user->{loginid_details};
    $args->{wallet_id} = $wallet->loginid;
    $args->{client_id} = $dxtrade_real_account->{account_id};
    throws_ok { $user->link_wallet_to_trading_account($args); } qr/CannotLinkVirtualAndReal/, 'cannot bind virtual wallet to a real dxtrade account';

    my $ctrader_real_loginid = $ctrader->new_account(
        account_type => 'real',
        market_type  => 'all',
        currency     => 'USD',
    )->{account_id};

    $args->{wallet_id} = $wallet->loginid;
    $args->{client_id} = $ctrader_real_loginid;
    throws_ok { $user->link_wallet_to_trading_account($args); } qr/CannotLinkVirtualAndReal/, 'cannot bind virtual wallet to a real ctrader account';

    subtest 'get list of linked accounts for user' => sub {
        my $account_links = $user->get_accounts_links;

        cmp_deeply(
            $account_links->{$client_vr->loginid},
            [{loginid => $wallet->loginid, platform => 'dwallet'}],
            'Wallet is linked to VR account'
        );
        cmp_deeply(
            $account_links->{MTD2000},
            [{loginid => $wallet->loginid, platform => 'dwallet'}],
            'Wallet is linked to MT5 account'
        );
        cmp_deeply(
            $account_links->{$dxtrade_account->{account_id}},
            [{loginid => $wallet->loginid, platform => 'dwallet'}],
            'Wallet is linked to DX account'
        );
        cmp_deeply(
            $account_links->{$ctrader_demo_loginid},
            [{loginid => $wallet->loginid, platform => 'dwallet'}],
            'Wallet is linked to ctrader demo'
        );
        cmp_deeply(
            $account_links->{$wallet->loginid},
            bag({
                    loginid  => $client_vr->loginid,
                    platform => 'dtrade'
                },
                {
                    loginid  => 'MTD2000',
                    platform => 'mt5'
                },
                {
                    loginid  => $dxtrade_account->{account_id},
                    platform => 'dxtrade'
                },
                {
                    loginid  => $ctrader_demo_loginid,
                    platform => 'ctrader'
                },
            ),
            'Wallet has links to all trading accounts'
        );
    };

    subtest 'get list of linked_accounts for a wallet' => sub {
        my $new_wallet = create_client('VRW');
        $new_wallet->set_default_account('USD');

        $user->add_client($new_wallet);

        cmp_deeply($new_wallet->linked_accounts, [], 'there is no linked_to trading accounts to this new wallet');

        cmp_deeply(
            $wallet->linked_accounts,
            bag({
                    loginid  => $client_vr->loginid,
                    platform => 'dtrade'
                },
                {
                    loginid  => 'MTD2000',
                    platform => 'mt5'
                },
                {
                    loginid  => $dxtrade_account->{account_id},
                    platform => 'dxtrade'
                },
                {
                    loginid  => $ctrader_demo_loginid,
                    platform => 'ctrader'
                },
            ),
            'returns correct list of linked_to trading account ids and wallet details'
        );
    };

    subtest 'get list of linked_accounts for a client' => sub {
        cmp_deeply($client_cr->linked_accounts, [], 'there is no wallet linked to this client');

        cmp_deeply(
            $client_vr->linked_accounts,
            [{loginid => $wallet->loginid, platform => 'dwallet'}],
            'returns correct linked wallet info for this client'
        );
    }
};

subtest 'update trading password' => sub {
    is $user->trading_password, undef, 'user has no trading password';

    lives_ok { $user->update_trading_password('Abcd1234'); } 'trading password saved';

    ok $user->trading_password, 'user has set trading password successfully';

    ok BOM::User::Password::checkpw('Abcd1234', $user->trading_password), 'trading password is OK';

    lives_ok { $user->update_dx_trading_password('Random123'); } 'deriv x trading password saved';

    ok $user->dx_trading_password, 'user has set deriv x trading password successfully';

    ok BOM::User::Password::checkpw('Random123', $user->dx_trading_password), 'deriv x trading password is OK';
};

subtest 'update user password' => sub {
    my $user_id = $user->{id};

    my @app_ids = create_apps($user->id);
    create_tokens($user, $client_vr, \@app_ids);

    ok $oauth->has_other_login_sessions($client_vr->loginid), 'There are open login sessions';
    my $refresh_tokens = $oauth->get_refresh_tokens_by_user_id($user->id);
    is scalar $refresh_tokens->@*, scalar @app_ids, 'refresh tokens have been generated correctly';

    my $hash_pw = BOM::User::Password::hashpw('Ijkl6789');
    is $user->update_user_password($hash_pw), 1, 'user password changed is OK';

    $refresh_tokens = $oauth->get_refresh_tokens_by_user_id($user_id);
    is scalar $refresh_tokens->@*, 0, 'refresh tokens have been revoked correctly';
    ok !$oauth->has_other_login_sessions($client_vr->loginid), 'User access tokens are revoked';
};

subtest 'update email' => sub {
    my $user_id = $user->{id};

    $client_vr->status->set('disabled', 'system', 'testing');
    my @app_ids = create_apps($user->id);
    create_tokens($user, $client_vr, \@app_ids);

    ok $oauth->has_other_login_sessions($client_vr->loginid), 'There are open login sessions';
    my $refresh_tokens = $oauth->get_refresh_tokens_by_user_id($user->id);
    is scalar $refresh_tokens->@*, scalar @app_ids, 'refresh tokens have been generated correctly';

    my $new_email = 'AN_email@anywhere.com';
    is $user->update_email($new_email), 1,             'user email changed is OK';
    is $user->email,                    lc $new_email, 'user\'s email was updated';

    for my $loginid (qw/CR10000 CR10001 CR10013/, $client_vr->loginid) {
        my $client = BOM::User::Client->new({
            loginid => $loginid,
        });
        is($client->email, lc $new_email, 'client email updated');
    }
    $refresh_tokens = $oauth->get_refresh_tokens_by_user_id($user_id);
    is scalar $refresh_tokens->@*, 0, 'refresh tokens have been revoked correctly';
    ok !$oauth->has_other_login_sessions($client_vr->loginid), 'User access tokens are revoked';
    $client_vr->status->clear_disabled;
};

subtest 'feature flag' => sub {
    my $user_flags = $user->get_feature_flag();

    foreach my $flag (keys %$user_flags) {
        is $user_flags->{$flag}, 0, 'default values returned correctly';
    }

    my $feature_flag = {wallet => 1};
    lives_ok { $user->set_feature_flag($feature_flag) } 'feature flags are being set';

    $user_flags = $user->get_feature_flag();

    foreach my $flag (keys %$feature_flag) {
        is $feature_flag->{$flag}, $user_flags->{$flag}, "flag $flag has been set correctly";
    }
};

subtest 'unlink social' => sub {
    lives_ok { $user->update_has_social_signup(1) } 'update has_social_signup';
    is $user->unlink_social, 1, 'user unlinked is OK';
    lives_ok { $user = BOM::User->new(id => $user->id); } 'reload user ok';
    lives_ok { $user->update_has_social_signup(0) } 'reset has_social_signup';
};

subtest 'Populate users table on signup' => sub {

    my @randstr = ("A" .. "Z", "a" .. "z");
    my $randstr;
    $randstr .= $randstr[rand @randstr] for 1 .. 9;

    my @randnum = ("0" .. "9");
    my $randnum;
    $randnum .= $randnum[rand @randnum] for 1 .. 9;

    my $loginid = 'MTD' . $randnum;
    $email = "test_http_${randstr}_${randnum}_\@testing.com";

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
    });

    $user = BOM::User->create(
        email          => $test_client->email,
        password       => $hash_pwd,
        email_verified => 1,
    );

    $user->add_loginid($loginid, 'mt5', 'demo', 'USD', {test => 'test'});

    my $mt5_logins = $user->loginid_details;

    is $mt5_logins->{$loginid}->{loginid},      $loginid, "Got correct 'loginid' value";
    is $mt5_logins->{$loginid}->{platform},     "mt5",    "Got correct 'platform' value";
    is $mt5_logins->{$loginid}->{account_type}, "demo",   "Got correct 'account_type' value";
    is $mt5_logins->{$loginid}->{currency},     "USD",    "Got correct 'currency' value";
    cmp_deeply $mt5_logins->{$loginid}->{attributes}, {test => 'test'}, "Got correct 'attributes' value";
};

subtest 'check mt5 regulated accs' => sub {
    my $test_client_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'testmt5@testing.com',
    });

    my $user_1 = BOM::User->create(
        email          => $test_client_1->email,
        password       => $hash_pwd,
        email_verified => 1,
    );

    #test for the real acc regular expressions and each segment of the group attribute
    $user_1->add_loginid('MTR00001', 'mt5', 'real', 'USD', {group => 'real\p01_ts04\financial\svg'});

    is $user_1->has_mt5_regulated_account, '0', "No real MT5 account, group details should not end with svg";

    $user_1->add_loginid('MTR00002', 'mt5', 'real', 'USD', {group => 'real\p01_ts04\gaming\topside'});

    is $user_1->has_mt5_regulated_account, '0', "No real MT5 account, subaccount cannot match gaming";

    $user_1->add_loginid('MTR00003', 'mt5', 'real', 'USD', {group => 'real\p01_ts05\financial\topside'});

    is $user_1->has_mt5_regulated_account, '0', "No real MT5 account, group details only match until ts04";

    $user_1->add_loginid('MTR00004', 'mt5', 'real', 'USD', {group => 'real\p01_ts04\financial\topside'});

    is $user_1->has_mt5_regulated_account, '1', "Client has a real MT5 account";

    #create another client as the sub returns 1 upon a single real mt5 acc detected
    my $test_client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'testmt6@testing.com',
    });

    my $user_2 = BOM::User->create(
        email          => $test_client_2->email,
        password       => $hash_pwd,
        email_verified => 1,
    );

    #test for the demo acc regular expressions and each segment of the group attribute
    $user_2->add_loginid('MTR00005', 'mt5', 'real', 'USD', {group => 'demo\test_financial'});

    is $user_2->has_mt5_regulated_account, '0', "No real MT5 account, group details should not be demo";

    $user_2->add_loginid('MTR00006', 'mt5', 'real', 'USD', {group => 'real\svg'});

    is $user_2->has_mt5_regulated_account, '0', "No real MT5 account, group details should not end with svg";

    $user_2->add_loginid('MTR00007', 'mt5', 'real', 'USD', {group => 'real\test_financial'});

    is $user_2->has_mt5_regulated_account, '1', "Client has a real MT5 account";

    subtest 'using mt5 conf' => sub {
        my $conf = BOM::Config::mt5_account_types();
        my $j    = 0;

        for my $group (keys $conf->%*) {
            $j++;

            my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email       => '0x' . $j . '+testing+mt5+conf@testing.com',
            });

            my $user = BOM::User->create(
                email          => $test_client->email,
                password       => $hash_pwd,
                email_verified => 1,
            );

            $user->add_loginid("MTR112358$j", 'mt5', 'real', 'USD', {group => $group});

            if (
                $conf->{$group}->{account_type} eq 'real' && List::Util::any { $conf->{$group}->{landing_company_short} eq $_ }
                qw/bvi labuan vanuatu/
                )
            {
                ok $user->has_mt5_regulated_account(use_mt5_conf => 1), "$group is regulated";
            } else {
                ok !$user->has_mt5_regulated_account(use_mt5_conf => 1), "$group is not regulated";
            }
        }
    };
};

subtest 'has_mt5_groups' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'has_mt5_groups@testing.com',
    });

    my $user = BOM::User->create(
        email          => $client->email,
        password       => $hash_pwd,
        email_verified => 1,
    );

    my %args = ();

    ok !$user->has_mt5_groups(%args), 'by default no mt5 loginids';

    $user->add_loginid('MTR22001', 'mt5', 'real', 'USD', {group => 'real\p01_ts04\financial\svg'});

    $args{type_of_account} = 'real';

    ok !$user->has_mt5_groups(%args), 'no regexes specified';

    $args{regexes} = ['^real'];

    ok $user->has_mt5_groups(%args), 'regexes match';

    $args{type_of_account} = 'demo';

    ok !$user->has_mt5_groups(%args), 'no demo accounts';

    $user->add_loginid('MTD22001', 'mt5', 'demo', 'USD', {group => 'demo\p01_ts04\financial\svg'});

    ok !$user->has_mt5_groups(%args), 'no regex match';

    $args{regexes} = ['^real', 'svg$'];

    ok $user->has_mt5_groups(%args), 'regex match';

    delete $args{regexes};
    $args{full_match} = ['test'];
    ok !$user->has_mt5_groups(%args), 'no full match';

    $args{full_match} = ['test', 'demo\p01_ts04\financial\svg'];
    ok $user->has_mt5_groups(%args), 'full match';

    $args{full_match} = ['test', 'demo\p01_ts04\financial\svg'];
    ok $user->has_mt5_groups(%args), 'full match';

    $args{type_of_account} = 'real';
    ok !$user->has_mt5_groups(%args), 'no full match';

    $args{full_match} = ['real\p01_ts04\financial\svg', 'demo\p01_ts04\financial\svg'];
    ok $user->has_mt5_groups(%args), 'full match';

    $args{full_match} = ['real\p02_ts04\financial\svg', 'demo\p01_ts04\financial\svg'];
    ok !$user->has_mt5_groups(%args), 'no full match';

    $args{type_of_account} = 'all';
    ok $user->has_mt5_groups(%args), 'full match';

    # key must be group
    $user->add_loginid('MTR3434334', 'mt5', 'real', 'USD', {g => 'dummy'});
    delete $args{regexes};
    $args{type_of_account} = 'real';
    $args{full_match}      = ['dummy'];

    ok !$user->has_mt5_groups(%args), 'has no valid dummy loginid';

    $user->add_loginid('MTR3434335', 'mt5', 'real', 'USD', {group => 'dummy'});
    delete $args{regexes};
    $args{type_of_account} = 'real';
    $args{full_match}      = ['dummy'];

    ok $user->has_mt5_groups(%args), 'now it has a valid dummy loginid';

    # undef attributes
    $user->add_loginid('MTR3434336', 'mt5', 'real', 'USD', undef);
    delete $args{regexes};
    $args{type_of_account} = 'real';
    $args{full_match}      = ['dummy'];

    ok $user->has_mt5_groups(%args), 'now it has a valid dummy loginid';
};

done_testing();

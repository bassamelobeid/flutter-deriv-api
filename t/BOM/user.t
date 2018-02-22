#!perl

use utf8;
binmode STDOUT, ':utf8';

use strict;
use warnings;

use Test::MockTime;
use Test::More tests => 12;
use Test::Exception;
use Test::Deep qw(cmp_deeply);
use Test::Warnings;

use Cache::RedisDB;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;
use BOM::Platform::Password;

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::Platform::Password::hashpw($password);

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
    $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->save;

    $user->add_loginid({loginid => $vr_1});
    $user->save;
}
'create user with loginid';

subtest 'test attributes' => sub {
    throws_ok { BOM::User->new } qr/BOM::User->new called without args/, 'new without args';
    throws_ok { BOM::User->new({badkey => 1234}) } qr/no email/, 'new without email';

    is $user->email,    $email,    'email ok';
    is $user->password, $hash_pwd, 'password ok';
};

my @loginids;
my $cr_2;
subtest 'default loginid & cookie' => sub {
    subtest 'only VR acc' => sub {
        @loginids = ($vr_1);
        cmp_deeply(\@loginids, [map { $_->loginid } $user->loginid], 'loginid match');

        my $def_client = ($user->clients)[0];
        is $def_client->loginid, $vr_1, 'no real acc, VR as default';

        my $cookie_str = "$vr_1:V:E";
        is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
    };

    subtest 'with real acc' => sub {
        $user->add_loginid({loginid => $cr_1});
        $user->save;

        push @loginids, $cr_1;
        cmp_deeply([sort @loginids], [sort map { $_->loginid } $user->loginid], 'loginids array match');

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
        cmp_deeply([sort @loginids], [sort map { $_->loginid } $user->loginid], 'loginids array match');

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

            cmp_deeply([sort @loginids], [sort map { $_->loginid } $user->loginid], 'loginids array match');

            my $def_client = ($user->clients)[0];
            is $def_client->loginid, $cr_2, '2nd real acc as default';

            my $cookie_str = "$cr_2:R:E+$vr_1:V:E+$cr_1:R:D";
            is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
        };

        subtest 'disable second real acc' => sub {
            lives_ok {
                $client_cr_new->set_status('disabled', 'system', 'testing');
                $client_cr_new->save;
            }
            'disable';

            cmp_deeply([sort @loginids], [sort map { $_->loginid } $user->loginid], 'loginids array match');

            my $def_client = ($user->clients)[0];
            is $def_client->loginid, $vr_1, 'VR acc as default';

            my $cookie_str = "$vr_1:V:E+$cr_1:R:D+$cr_2:R:D";
            is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
        };

        subtest 'disable VR acc' => sub {
            lives_ok {
                $client_vr->set_status('disabled', 'system', 'testing');
                $client_vr->save;
            }
            'disable';

            cmp_deeply([sort @loginids], [sort map { $_->loginid } $user->loginid], 'loginids array match');

            my $def_client = ($user->clients)[0];
            is $def_client, undef, 'all acc disabled, no default';

            my $cookie_str = "$cr_1:R:D+$cr_2:R:D+$vr_1:V:D";
            is $user->loginid_list_cookie_val, $cookie_str, 'cookie string OK';
        };
    };
};

subtest 'user / email from loginid not allowed' => sub {
    my $user_2 = BOM::User->new({
        email => $vr_1,
    });
    isnt($user_2, "BOM::User", "Cannot create User using loginid");
};

subtest 'create user by loginid' => sub {
    lives_ok {
        my $user_2 = BOM::User->new({
            loginid => $vr_1,
        });
        is $user_2->id, $user->id, 'found correct user by loginid';
        $user_2 = BOM::User->new({
            loginid => 'does not exist',
        });
        is $user_2, undef, 'looking up non-existent loginid results in undef';
    }
    'survived user lookup by loginid';
};

subtest 'User Login' => sub {
    subtest 'cannot login if disabled' => sub {
        $client_vr->set_status('disabled', 'system', 'testing');
        $client_vr->save;
        $status = $user->login(%pass);
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
            $user3->add_loginid({loginid => $cr_3->loginid});
            $user3->add_loginid({loginid => $cr_31->loginid});
            $user3->save;
        }
        'create user with cr accounts only';

        subtest 'cannot login if he has all self excluded account' => sub {
            my $exclude_until_3  = Date::Utility->new()->plus_time_interval('365d')->date;
            my $exclude_until_31 = Date::Utility->new()->plus_time_interval('300d')->date;

            $cr_3->set_exclusion->exclude_until($exclude_until_3);
            $cr_3->save;
            $cr_31->set_exclusion->exclude_until($exclude_until_31);
            $cr_31->save;

            $status = $user3->login(%pass);

            ok $status->{error} =~ /Sorry, you have excluded yourself until $exclude_until_31/,
                'It should return the earlist until date in message error';
        };

        subtest 'cannot login if he has all self timeouted account' => sub {
            my $timeout_until_3  = Date::Utility->new()->plus_time_interval('2d');
            my $timeout_until_31 = Date::Utility->new()->plus_time_interval('1d');

            $cr_3->set_exclusion->timeout_until($timeout_until_3->epoch);
            $cr_3->save;
            $cr_31->set_exclusion->timeout_until($timeout_until_31->epoch);
            $cr_31->save;

            $status = $user3->login(%pass);

            my $timeout_until_31_date = $timeout_until_31->date;
            ok $status->{error} =~ /Sorry, you have excluded yourself until $timeout_until_31_date/,
                'It should return the earlist until date in message error';
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
        my $login_history = $user->get_last_successful_login_history();
        is $login_history->{action}, 'login', 'correct login history action';
        is $login_history->{status}, 1,       'correct login history status';
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
        my $login_history = $user->get_last_successful_login_history();
        is $login_history->{action}, 'login', 'correct last successful login history action';
        is $login_history->{status}, 1,       'correct last successful login history status';
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

subtest 'MT5 logins' => sub {
    $user->add_loginid({loginid => 'MT1000'});
    $user->save;
    my @mt5_logins = $user->mt5_logins;
    cmp_deeply(\@mt5_logins, ['MT1000'], 'MT5 logins match');

    $user->add_loginid({loginid => 'MT2000'});
    $user->save;
    @mt5_logins = $user->mt5_logins;
    cmp_deeply(\@mt5_logins, ['MT1000', 'MT2000'], 'MT5 logins match');

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
        $user_ch->save;

        $user_ch->add_loginid({loginid => $vrch_loginid});
        $user_ch->save;
    }
    'create user with loginid';

    subtest 'test attributes' => sub {
        is $user_ch->email,    $email_ch, 'email ok';
        is $user_ch->password, $hash_pwd, 'password ok';
    };
};

sub write_file {
    my ($name, $content) = @_;

    open my $f, '>', $name or die "Cannot open $name for write: $!";
    print $f $content or die "Cannot write $name: $!";
    close $f or die "Cannot write/close $name: $!";
    return;
}

subtest 'MirrorBinaryUserId' => sub {
    plan tests => 12;
    use YAML::XS qw/LoadFile/;
    use BOM::Platform::Script::MirrorBinaryUserId;
    use User::Client;

    my $cfg            = LoadFile '/etc/rmg/userdb.yml';
    my $pgservice_conf = "/tmp/pgservice.conf.$$";
    my $pgpass_conf    = "/tmp/pgpass.conf.$$";
    my $dbh;
    my $t = $ENV{DB_POSTFIX} // '';
    lives_ok {
        write_file $pgservice_conf, <<"CONF";
[user01]
host=$cfg->{ip}
port=5436
user=write
dbname=users$t
CONF

        write_file $pgpass_conf, <<"CONF";
$cfg->{ip}:5436:users$t:write:$cfg->{password}
CONF
        chmod 0400, $pgpass_conf;

        @ENV{qw/PGSERVICEFILE PGPASSFILE/} = ($pgservice_conf, $pgpass_conf);

        $dbh = BOM::Platform::Script::MirrorBinaryUserId::userdb;
    }
    'setup';

    # at this point we have 9 rows in the queue: 2x VRTC, 4x CR, 2x MT and 1x VRCH
    my $queue = $dbh->selectall_arrayref('SELECT binary_user_id, loginid FROM q.add_loginid');

    is $dbh->selectcol_arrayref('SELECT count(*) FROM q.add_loginid')->[0], 9, 'got expected number of queue entries';

    BOM::Platform::Script::MirrorBinaryUserId::run_once $dbh;
    is $dbh->selectcol_arrayref('SELECT count(*) FROM q.add_loginid')->[0], 0, 'all queue entries processed';

    for my $el (@$queue) {
        if ($el->[1] =~ /^MT/) {
            ok 1, "survived MT account $el->[1]";
        } else {
            my $client = User::Client->new({loginid => $el->[1]});
            is $client->binary_user_id, $el->[0], "$el->[1] has binary_user_id $el->[0]";
        }
    }
};

subtest 'clients_for_landing_company' => sub {
    $user = BOM::User->new({email => $email},);
    my @clients = $user->clients_for_landing_company('costarica');
    is(scalar @clients, 2, "one cr account");
    is_deeply([map { $_->landing_company->short } @clients], [('costarica') x 2], 'lc correct');
    is_deeply([map { $_->loginid } @clients], [qw/CR10000 CR10001/], "clients are correct");
};

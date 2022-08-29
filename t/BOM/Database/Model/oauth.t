#!perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Deep;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init :disable_redis_cleanup);
use BOM::Test::Data::Utility::UnitTestRedis;

my $m            = BOM::Database::Model::OAuth->new;
my $test_loginid = 'CR10002';
my $test_user_id = 999;

## clear
$m->dbic->dbh->do("DELETE FROM oauth.access_token");
$m->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
$m->dbic->dbh->do("DELETE FROM oauth.official_apps");
$m->dbic->dbh->do("DELETE FROM oauth.apps");

my $app1 = $m->create_app({
    name                  => 'App 1',
    scopes                => ['read', 'payments', 'trade'],
    homepage              => 'http://www.example.com/',
    github                => 'https://github.com/binary-com/binary-static',
    user_id               => $test_user_id,
    redirect_uri          => 'https://www.example.com',
    verification_uri      => 'https://www.example.com/verify',
    app_markup_percentage => 3,
});
my $test_appid = $app1->{app_id};
is $app1->{homepage},         'http://www.example.com/',        'homepage is correct';
is $app1->{verification_uri}, 'https://www.example.com/verify', 'verification_uri is correct';

my $verification_uri = $m->get_verification_uri_by_app_id($test_appid);
is $app1->{verification_uri}, $verification_uri, 'get_verification_uri_by_app_id';

my $names          = $m->get_names_by_app_id($app1->{app_id});
my $expected_names = {$app1->{app_id} => $app1->{name}};
is_deeply $names, $expected_names, "got correct name for single app";

## it's in test db
my $app = $m->verify_app($test_appid);
is $app->{id}, $test_appid;

## test verify_app
lives_ok {
    $m->verify_app($_) for ('abcd', '9223372036854775808', '9999999999999999999999999');
}
'verify_app handles invalid app_id values as well as numbers that exceed the bigint range';

my $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 0, 'not confirmed';

ok $m->confirm_scope($test_appid, $test_loginid), 'confirm scope';
$is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 1, 'confirmed after confirm_scope';

my ($access_token, $exp) = $m->store_access_token_only($test_appid, $test_loginid);
ok $access_token;
my ($result_loginid, $t, $ua_fp) = @{$m->get_token_details($access_token)}{qw/loginid creation_time ua_fingerprint/};
is $result_loginid,                        $test_loginid, 'got correct loginid from token';
is $m->get_app_id_by_token($access_token), $test_appid,   'get_app_id_by_token';

my @scopes = $m->get_scopes_by_access_token($access_token);
is_deeply([sort @scopes], ['payments', 'read', 'trade'], 'scopes are right');

## test update_app
$app1 = $m->update_app(
    $test_appid,
    {
        name             => 'App 1',
        scopes           => ['read', 'payments', 'trade'],
        redirect_uri     => 'https://www.example.com/callback',
        verification_uri => 'https://www.example.com/verify_updated',
        homepage         => 'http://www.example2.com/',
    });
is $app1->{redirect_uri},          'https://www.example.com/callback',            'redirect_uri is updated';
is $app1->{verification_uri},      'https://www.example.com/verify_updated',      'verification_uri is updated';
is $app1->{homepage},              'http://www.example2.com/',                    'homepage is updated';
is $app1->{app_markup_percentage}, 3,                                             'app_markup_percentage not updated';
is $app1->{github},                'https://github.com/binary-com/binary-static', 'github not updated';

### get app_register/app_list/app_get
my $get_app = $m->get_app($test_user_id, $app1->{app_id});
is_deeply($app1, $get_app, 'same on get');

my $app2 = $m->create_app({
    name         => 'App 2',
    scopes       => ['read', 'admin'],
    user_id      => $test_user_id,
    redirect_uri => 'https://www.example2.com',
});
my $get_apps = $m->get_apps_by_user_id($test_user_id);
is_deeply($get_apps, [$app1, $app2], 'get_apps_by_user_id ok');

$get_apps = $m->get_app_ids_by_user_id($test_user_id);
is_deeply($get_apps, [$app1->{app_id}, $app2->{app_id}], 'get_app_ids_by_user_id ok');

$get_apps = $m->user_has_app_id($test_user_id, $app1->{app_id});
is $get_apps, $app1->{app_id}, 'user_has_app_id yes';

$get_apps = $m->user_has_app_id($test_user_id, -1);
is $get_apps, undef, 'user_has_app_id no';

$names          = $m->get_names_by_app_id([$app1->{app_id}, $app2->{app_id}]);
$expected_names = {
    $app1->{app_id} => $app1->{name},
    $app2->{app_id} => $app2->{name}};
is_deeply $names, $expected_names, "got correct name for multiple apps";

## test get_used_apps_by_loginid and revoke
my $used_apps = $m->get_used_apps_by_loginid($test_loginid);
is scalar(@{$used_apps}), 1;
is $used_apps->[0]->{app_id}, $test_appid, 'app_id 1';
is_deeply([sort @{$used_apps->[0]->{scopes}}], ['payments', 'read', 'trade'], 'scopes are right');
ok $used_apps->[0]->{last_used}, 'last_used ok';

ok $m->revoke_app($test_appid, $test_loginid);
$is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 0, 'not confirmed after revoke';
($result_loginid, $t, $ua_fp) = @{$m->get_token_details($access_token)}{qw/loginid creation_time ua_fingerprint/};
is $result_loginid, undef, 'token is not valid anymore';
# delete app_ids to avoid confusing
my $sql = 'delete from oauth.apps where binary_user_id = ?';
$m->dbic->dbh->do($sql, undef, $test_user_id);

subtest 'revoke tokens by loginid and app_id' => sub {
    my $app1 = $m->create_app({
        name         => 'App 1',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example.com',
    });
    my $app2 = $m->create_app({
        name         => 'App 2',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example2.com',
    });
    my $app3 = $m->create_app({
        name         => 'App 3',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example3.com',
    });
    my $get_apps = $m->get_apps_by_user_id($test_user_id);
    is_deeply($get_apps, [$app1, $app2, $app3], 'get_apps_by_user_id ok');

    my @app_ids  = ($app1->{app_id}, $app2->{app_id}, $app3->{app_id});
    my @loginids = ('CR1234', 'VRTC1234');

    foreach my $loginid (@loginids) {
        foreach my $app_id (@app_ids) {
            ok $m->confirm_scope($app_id, $loginid), 'confirm scope';
            my $is_confirmed = $m->is_scope_confirmed($app_id, $loginid);
            is $is_confirmed, 1, 'confirmed after confirm_scope';

            my ($access_token) = $m->store_access_token_only($app_id, $loginid);
            ok $access_token;
            ($result_loginid, $t, $ua_fp) = @{$m->get_token_details($access_token)}{qw/loginid creation_time ua_fingerprint/};
            is $result_loginid,                        $loginid, 'correct loginid from token details';
            is $m->get_app_id_by_token($access_token), $app_id,  'get_app_id_by_token';
        }
    }

    # setup BO app, id = 4
    my $sql = 'INSERT INTO oauth.apps (id, name, binary_user_id, redirect_uri, scopes) VALUES (?,?,?,?,?)';
    $m->dbic->dbh->do($sql, undef, 4, 'Binary.com backoffice', 1, 'https://www.binary.com/en/logged_inws.html', '{read}');

    foreach my $loginid (@loginids) {
        my @cnt = $m->dbic->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 3, "access tokens [$loginid]";

        is $m->has_other_login_sessions($loginid), 1, "$loginid has other oauth token";

        is $m->revoke_tokens_by_loginid_app($loginid, $app1->{app_id}), 1, 'revoke_tokens_by_loginid_app';
        @cnt = $m->dbic->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 2, "access tokens [$loginid]";

        is $m->revoke_tokens_by_loginid($loginid), 1, 'revoke_tokens_by_loginid';
        @cnt = $m->dbic->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 0, "revoked access tokens [$loginid]";

        isnt $m->has_other_login_sessions($loginid), 1, "$loginid has NO oauth token";

        # Backoffice impersonate app id = 4, exclude in ->has_other_login_sessions
        my ($bo_token) = $m->store_access_token_only(4, $loginid);
        @cnt = $m->dbic->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0],                                  1, "BO access tokens [$loginid]";
        isnt $m->has_other_login_sessions($loginid), 1, "$loginid has NO oauth token, beside for BO impersonate";
    }
};

subtest 'remove user confirm on scope changes' => sub {
    my $app1 = $m->create_app({
        name         => 'App 1 Change',
        scopes       => ['read', 'trade'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example.com',
    });
    my $test_appid = $app1->{app_id};

    my $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
    is $is_confirmed, 0, 'not confirmed';

    ok $m->confirm_scope($test_appid, $test_loginid), 'confirm scope';
    $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
    is $is_confirmed, 1, 'confirmed after confirm_scope';

    ## update app without scope change
    $app1 = $m->update_app(
        $test_appid,
        {
            name         => 'App 1 Change 2',
            scopes       => ['read', 'trade'],
            redirect_uri => 'https://www.example.com/callback',
        });
    $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
    is $is_confirmed, 1, 'is still confirmed if scope is not changed';

    $app1 = $m->update_app(
        $test_appid,
        {
            name         => 'App 1 Change 2',
            scopes       => ['read', 'trade', 'admin'],
            redirect_uri => 'https://www.example.com/callback',
        });
    $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
    is $is_confirmed, 0, 'is not confirmed if scope is changed';

    my ($access_token) = $m->store_access_token_only($test_appid, $test_loginid);
    my @scopes = $m->get_scopes_by_access_token($access_token);
    is_deeply([sort @scopes], ['admin', 'read', 'trade'], 'scopes are updated');
};

subtest 'block app' => sub {
    my $app1 = $m->create_app({
        name         => 'App 1010',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example.com',
        active       => 1
    });

    is $app1->{active}, 1, 'the initial state is active';
    $m->block_app($app1->{app_id});
    my $get_app = $m->get_app($test_user_id, $app1->{app_id}, 0);
    is $get_app->{active}, 0, 'app should be de-activated';

};

subtest 'unblock app' => sub {
    my $app1 = $m->create_app({
        name         => 'App 1010',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example.com',
        active       => 1
    });

    $m->block_app($app1->{app_id}, $test_user_id + 1);
    my $get_app = $m->get_app($test_user_id, $app1->{app_id});
    is $get_app->{active}, 1, 'app should not be de-actived because the user id is wrong';

    $m->block_app($app1->{app_id});
    $get_app = $m->get_app($test_user_id, $app1->{app_id}, 0);
    is $get_app->{active}, 0, 'app should be de-activated without user id';

    $m->unblock_app($app1->{app_id});
    $get_app = $m->get_app($test_user_id, $app1->{app_id});
    is $get_app->{active}, 1, 'app should be activated';

    $m->block_app($app1->{app_id}, $test_user_id);
    $get_app = $m->get_app($test_user_id, $app1->{app_id}, 0);
    is $get_app->{active}, 0, 'app should be de-activated with right user id';

    $m->unblock_app($app1->{app_id});
    $get_app = $m->get_app($test_user_id, $app1->{app_id});
    is $get_app->{active}, 1, 'app should be activated';

};

subtest 'get app by id' => sub {
    my $app1 = $m->create_app({
        name         => 'App 1020',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example.com',
        active       => 1
    });

    my $get_app1      = $m->get_app($test_user_id, $app1->{app_id});
    my $retrieved_app = $m->get_app_by_id($app1->{app_id});
    is $get_app1->{name}, $retrieved_app->{name}, 'app retrieved from DB and created app should be the same ';

};
subtest 'Is app internal' => sub {
    my $app1 = $m->create_app({
        name         => 'App internal',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example.com',
        active       => 1
    });

    my $sql = 'INSERT INTO  oauth.official_apps VALUES (?, true, true)';
    $m->dbic->dbh->do($sql, undef, $app1->{app_id});
    is($m->is_internal($app1->{app_id}), 1, 'Is internal app true');

    # Not Internal
    my $app2 = $m->create_app({
        name         => 'App internal',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example.com',
        active       => 1
    });

    $sql = 'INSERT INTO  oauth.official_apps VALUES (?, true, false)';
    $m->dbic->dbh->do($sql, undef, $app2->{app_id});
    is($m->is_internal($app2->{app_id}), 0, 'Is internal app false');

};

subtest 'application tokens' => sub {
    my $tests = [{
            app    => 'animales en español',
            tokens => [qw/perro gato caballo/]
        },
        {
            app    => 'animals in english',
            tokens => [qw/dog cat horse/]
        },
        {
            app    => 'animaux en français',
            tokens => [qw/chien chat cheval/]
        },
        {
            app    => 'animais em portugues',
            tokens => [qw/cachorro gato cavalo/]}];

    for my $test ($tests->@*) {
        my $app = $m->create_app({
            name         => $test->{app},
            scopes       => ['read', 'admin'],
            user_id      => $test_user_id,
            redirect_uri => 'https://www.example.com',
            active       => 1
        });

        for my $token ($test->{tokens}->@*) {
            ok $m->create_app_token($app->{app_id}, $token), 'Token created';
        }

        my $app_tokens = $m->get_app_tokens($app->{app_id});
        cmp_deeply $app_tokens, bag($test->{tokens}->@*), 'We got the expected tokens';
    }
};

subtest 'refresh_token' => sub {
    my ($test_app, $test_app2) = (
        $m->create_app({
                name         => 'refresh_token',
                scopes       => ['read', 'admin'],
                user_id      => $test_user_id,
                redirect_uri => 'https://www.example.com',
                active       => 1
            }
        ),
        $m->create_app({
                name         => 'refresh_token2',
                scopes       => ['read', 'admin'],
                user_id      => $test_user_id,
                redirect_uri => 'https://www.example2.com',
                active       => 1
            }));

    my $tests = [{
            token_length      => 28,
            full_token_length => 31,
            expiry_time       => 86400,
        },
        {
            token_length      => 29,
            full_token_length => 32,
            expiry_time       => 86400,
        }];

    my @tokens;
    foreach my $test ($tests->@*) {
        my $token  = $m->generate_refresh_token($test_user_id, $test_app->{app_id},  $test->{token_length}, $test->{expiry_time});
        my $token2 = $m->generate_refresh_token($test_user_id, $test_app2->{app_id}, $test->{token_length}, $test->{expiry_time});
        push @tokens, $token, $token2;

        is length $token, $test->{full_token_length}, 'token has been created correctly with the provided length';
        ok $token =~ /^r1-[a-zA-Z0-9]+$/, 'token format is correct';

        my $record = $m->get_user_app_details_by_refresh_token($token);
        ok defined $record, 'returns a single defined record when the token is valid';
    }

    is $m->get_user_app_details_by_refresh_token("INVALID_TOKEN"), undef, 'returns an undef when invalid token is provided';

    my ($token1, $token2) = @tokens;
    my $token_info = $m->get_user_app_details_by_refresh_token($token1);
    my ($user_id, $app_id) = ($token_info->{binary_user_id}, $token_info->{app_id});

    my $retreived_token            = $m->get_refresh_tokens_by_user_app_id($user_id, $app_id);
    my $retreived_token_by_user_id = $m->get_refresh_tokens_by_user_id($user_id);

    is scalar $retreived_token->@*,            scalar @tokens / 2, 'retreived both correctly';
    is scalar $retreived_token_by_user_id->@*, @tokens,            'tokens retreived by user id correctly';

    $m->revoke_refresh_tokens_by_user_app_id($user_id, $app_id);
    $retreived_token = $m->get_refresh_tokens_by_user_app_id($user_id, $app_id);
    is scalar $retreived_token->@*, 0, "refresh_tokens has been revoked for $app_id and $user_id correctly";

    $retreived_token_by_user_id = $m->get_refresh_tokens_by_user_id($user_id);
    is scalar $retreived_token_by_user_id->@*, 2, 'tokens retreived by user id correctly';

    $m->revoke_refresh_tokens_by_user_id($user_id, $app_id);
    $retreived_token_by_user_id = $m->get_refresh_tokens_by_user_id($user_id);
    is scalar $retreived_token_by_user_id->@*, 0, 'tokens revoked by user id correctly';

    subtest 'with retry' => sub {
        my $db_mock = Test::MockModule->new('DBIx::Connector');
        my $token;
        my $context;
        my $runs = 0;

        $db_mock->mock(
            'run',
            sub {
                $runs++;
                return ($token);
            });

        my $oauth_mock = Test::MockModule->new('BOM::Database::Model::OAuth');
        $oauth_mock->mock(
            'generate_refresh_token',
            sub {
                $context = [@_];
                return $oauth_mock->original('generate_refresh_token')->(@_);
            });

        $runs = 0;
        is $m->generate_refresh_token($test_user_id, $test_app->{app_id}, 16, 600, 5), undef, 'Give up';
        is $runs,                                                                      6,     'Original attempt + 5 retries';

        $db_mock->mock(
            'run',
            sub {
                $runs++;

                $token = 'ok' if $runs == 2;

                return ($token);
            });

        $runs = 0;
        is $m->generate_refresh_token($test_user_id, $test_app->{app_id}, 16, 600, 5), 'ok', 'Got a token after retry';
        is $runs,                                                                      2,    '2 runs';

        $db_mock->unmock_all;
        $oauth_mock->unmock_all;
    };
};

done_testing();

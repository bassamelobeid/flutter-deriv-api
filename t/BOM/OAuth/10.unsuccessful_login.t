use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::OAuth::Common;
use BOM::User::Password;
use BOM::User;
use BOM::Config::Redis;
use BOM::Database::Model::OAuth;
use BOM::User::TOTP;

is(BOM::OAuth::Common->BLOCK_TRIGGER_COUNT,  "10",    "Threshold for unsuccessful login ip");
is(BOM::OAuth::Common->BLOCK_MIN_DURATION,   "300",   "Threshold for minimum duration in seconds");
is(BOM::OAuth::Common->BLOCK_MAX_DURATION,   "86400", "Threshold for maximum duration in seconds");
is(BOM::OAuth::Common->BLOCK_TRIGGER_WINDOW, "300",   "Threshold trigger window in seconds");

my $redis     = BOM::Config::Redis::redis_auth_write();
my $t         = Test::Mojo->new('BOM::OAuth');
my $mock      = Test::MockModule->new('BOM::OAuth::O');
my $stats_inc = {};

$mock->mock(
    'stats_inc',
    sub {
        my ($key) = @_;

        $stats_inc->{$key} = 1;
    });

subtest 'Disabled TOTP' => sub {
    my $client = create_client('block+ip@binary.com', 'Abcd1243', 'CR');
    my $app    = create_app('Testing for IP Blocks');
    my $brand  = 'binary';
    my $app_id = $app->{app_id};

    my $url = "/authorize?app_id=$app_id&brand=$brand";
    $t = $t->get_ok($url)->content_like(qr/login/);

    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    redis_clear($redis, 'ip', '127.0.0.1');

    note 'Invalid password';
    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => 'block+ip@binary.com',
            password   => 'Abcd12435',
            csrf_token => $csrf_token
        });

    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 1,
            backoff => undef,
            blocked => undef,
        });
    redis_test(
        $redis, 'user',
        $client->user->id,
        {
            counter => undef,
            backoff => undef,
            blocked => undef,
        });

    note 'Invalid password one more time';
    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => 'block+ip@binary.com',
            password   => 'Abcd12435',
            csrf_token => $csrf_token
        });

    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 2,
            backoff => undef,
            blocked => undef,
        });

    note 'Edit the counter to reach the threshold';
    redis_counter_edit($redis, 'ip', '127.0.0.1', BOM::OAuth::Common->BLOCK_TRIGGER_COUNT);

    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => 'block+ip@binary.com',
            password   => 'Abcd12435',
            csrf_token => $csrf_token
        });

    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 11,
            backoff => BOM::OAuth::Common->BLOCK_MIN_DURATION,
            blocked => 1,
        });

    note 'IP Blocked';
    $stats_inc = {};

    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => 'block+ip@binary.com',
            password   => 'Abcd12435',
            csrf_token => $csrf_token
        });

    ok $stats_inc->{'login.authorizer.block.hit'}, 'Attempt blocked';

    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 11,
            backoff => BOM::OAuth::Common->BLOCK_MIN_DURATION,
            blocked => 1,
        });

    note 'Hit the Backoff';
    redis_unblock($redis, 'ip', '127.0.0.1');

    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => 'block+ip@binary.com',
            password   => 'Abcd12435',
            csrf_token => $csrf_token
        });

    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 12,
            backoff => BOM::OAuth::Common->BLOCK_MIN_DURATION * 2,
            blocked => 1,
        });

    note 'Hit the Backoff max duration';
    redis_unblock($redis, 'ip', '127.0.0.1');
    redis_backoff_edit($redis, 'ip', '127.0.0.1', BOM::OAuth::Common->BLOCK_MAX_DURATION);

    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => 'block+ip@binary.com',
            password   => 'Abcd12435',
            csrf_token => $csrf_token
        });

    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 13,
            backoff => BOM::OAuth::Common->BLOCK_MAX_DURATION,
            blocked => 1,
        });

    note 'Good password but blocked';
    $stats_inc = {};

    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => 'block+ip@binary.com',
            password   => 'Abcd1243',
            csrf_token => $csrf_token
        });

    ok $stats_inc->{'login.authorizer.block.hit'}, 'Attempt blocked';

    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 13,
            backoff => BOM::OAuth::Common->BLOCK_MAX_DURATION,
            blocked => 1,
        });

    note 'Let it pass';
    redis_clear($redis, 'ip', '127.0.0.1');
    $stats_inc = {};

    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => 'block+ip@binary.com',
            password   => 'Abcd1243',
            csrf_token => $csrf_token
        });

    ok !$stats_inc->{'login.authorizer.block.hit'}, 'Attempt not blocked';
    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => undef,
            backoff => undef,
            blocked => undef,
        });
};

subtest 'Enabled TOTP' => sub {
    $t = $t->reset_session;

    my $secret_key = BOM::User::TOTP->generate_key();
    my $client     = create_client('block+totp@binary.com', 'Abcd1243', 'CR', $secret_key);
    my $app        = create_app('Testing for IP Blocks');
    my $app_id     = $app->{app_id};

    redis_clear($redis, 'ip',   '127.0.0.1');
    redis_clear($redis, 'user', $client->user->id);

    note 'Invalid TOTP';
    invalid_totp_login('block+totp@binary.com', 'Abcd1243', $secret_key, 'binary', $app_id);
    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 1,
            backoff => undef,
            blocked => undef,
        });
    redis_test(
        $redis, 'user',
        $client->user->id,
        {
            counter => 1,
            backoff => undef,
            blocked => undef,
        });

    note 'Invalid TOTP once again';
    invalid_totp_login('block+totp@binary.com', 'Abcd1243', $secret_key, 'binary', $app_id);
    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 2,
            backoff => undef,
            blocked => undef,
        });
    redis_test(
        $redis, 'user',
        $client->user->id,
        {
            counter => 2,
            backoff => undef,
            blocked => undef,
        });

    note 'Edit the counter to reach the threshold (only for the user)';
    redis_counter_edit($redis, 'user', $client->user->id, BOM::OAuth::Common->BLOCK_TRIGGER_COUNT);
    invalid_totp_login('block+totp@binary.com', 'Abcd1243', $secret_key, 'binary', $app_id);
    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 3,
            backoff => undef,
            blocked => undef,
        });
    redis_test(
        $redis, 'user',
        $client->user->id,
        {
            counter => 11,
            backoff => BOM::OAuth::Common->BLOCK_MIN_DURATION,
            blocked => 1,
        });

    note 'User Blocked';
    $stats_inc = {};
    invalid_totp_login('block+totp@binary.com', 'Abcd1243', $secret_key, 'binary', $app_id);
    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 3,
            backoff => undef,
            blocked => undef,
        });
    redis_test(
        $redis, 'user',
        $client->user->id,
        {
            counter => 11,
            backoff => BOM::OAuth::Common->BLOCK_MIN_DURATION,
            blocked => 1,
        });

    ok $stats_inc->{'login.authorizer.block.hit'}, 'Attempt blocked';

    note 'Hit the Backoff max duration';
    redis_unblock($redis, 'user', $client->user->id);
    redis_backoff_edit($redis, 'user', $client->user->id, BOM::OAuth::Common->BLOCK_MAX_DURATION);
    invalid_totp_login('block+totp@binary.com', 'Abcd1243', $secret_key, 'binary', $app_id);
    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => 4,
            backoff => undef,
            blocked => undef,
        });
    redis_test(
        $redis, 'user',
        $client->user->id,
        {
            counter => 12,
            backoff => BOM::OAuth::Common->BLOCK_MAX_DURATION,
            blocked => 1,
        });

    note 'Let it pass';
    redis_clear($redis, 'ip',   '127.0.0.1');
    redis_clear($redis, 'user', $client->user->id);
    valid_totp_login('block+totp@binary.com', 'Abcd1243', $secret_key, 'binary', $app_id);
    $stats_inc = {};

    ok !$stats_inc->{'login.authorizer.block.hit'}, 'Attempt not blocked';
    redis_test(
        $redis, 'ip',
        '127.0.0.1',
        {
            counter => undef,
            backoff => undef,
            blocked => undef,
        });
    redis_test(
        $redis, 'user',
        $client->user->id,
        {
            counter => undef,
            backoff => undef,
            blocked => undef,
        });
};

sub valid_totp_login {
    my ($email, $password, $secret_key, $brand, $app_id) = @_;

    my $url = "/authorize?app_id=$app_id&brand=$brand";
    $t = $t->get_ok($url)->content_like(qr/login/);

    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => $email,
            password   => $password,
            csrf_token => $csrf_token,
        });

    $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    $t->post_ok(
        "/authorize?app_id=$app_id" => form => {
            totp_proceed => 1,
            otp          => Authen::OATH->new()->totp($secret_key),
            csrf_token   => $csrf_token,
        });
}

sub invalid_totp_login {
    my ($email, $password, $secret_key, $brand, $app_id) = @_;

    my $url = "/authorize?app_id=$app_id&brand=$brand";
    $t = $t->get_ok($url)->content_like(qr/login/);

    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    $t->post_ok(
        $url => form => {
            login      => 1,
            email      => $email,
            password   => $password,
            csrf_token => $csrf_token,
        });

    $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    $t->post_ok(
        "/authorize?app_id=$app_id" => form => {
            totp_proceed => 1,
            otp          => Authen::OATH->new()->totp($secret_key) - 100,
            csrf_token   => $csrf_token,
        });
}

sub redis_backoff_edit {
    my ($redis, $key, $identifier, $value) = @_;

    my $backoff_key = 'oauth::backoff_by_' . $key . '::' . $identifier;

    $redis->set($backoff_key, $value);
}

sub redis_counter_edit {
    my ($redis, $key, $identifier, $value) = @_;

    my $counter_key = 'oauth::failure_count_by_' . $key . '::' . $identifier;

    $redis->set($counter_key, $value);
}

sub redis_test {
    my ($redis, $key, $identifier, $tests) = @_;

    my $counter_key = 'oauth::failure_count_by_' . $key . '::' . $identifier;
    my $backoff_key = 'oauth::backoff_by_' . $key . '::' . $identifier;
    my $blocked_key = 'oauth::blocked_by_' . $key . '::' . $identifier;

    is $redis->get($counter_key), $tests->{counter}, 'Expected counter value found';
    is $redis->get($backoff_key), $tests->{backoff}, 'Expected backoff value found';
    is $redis->get($blocked_key), $tests->{blocked}, 'Expected blocked value found';
}

sub redis_unblock {
    my ($redis, $key, $identifier) = @_;

    my $blocked_key = 'oauth::blocked_by_' . $key . '::' . $identifier;

    $redis->del($blocked_key);
}

sub redis_clear {
    my ($redis, $key, $identifier) = @_;

    my $counter_key = 'oauth::failure_count_by_' . $key . '::' . $identifier;
    my $backoff_key = 'oauth::backoff_by_' . $key . '::' . $identifier;
    my $blocked_key = 'oauth::blocked_by_' . $key . '::' . $identifier;

    $redis->del($counter_key);
    $redis->del($backoff_key);
    $redis->del($blocked_key);
}

sub create_app {
    my $name = shift;

    my $oauth = BOM::Database::Model::OAuth->new;
    $oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
    $oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
    $oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='$name'");
    my $app = $oauth->create_app({
        name         => $name,
        user_id      => 1,
        scopes       => ['read', 'trade', 'admin'],
        redirect_uri => 'https://www.example.com/'
    });

    return $app;
}

sub create_client {
    my ($email, $password, $broker_code, $secret_key) = @_;

    my $hash_pwd = BOM::User::Password::hashpw($password);
    my $client   = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker_code,
    });
    $client->email($email);
    $client->save;

    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    $user->add_client($client);

    $user->update_totp_fields(
        secret_key      => $secret_key,
        is_totp_enabled => 1
    ) if $secret_key;

    return $client;
}

done_testing();


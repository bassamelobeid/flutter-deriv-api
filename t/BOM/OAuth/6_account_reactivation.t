use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;

use Authen::OATH;
use Brands;

use BOM::User::Password;
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::Config::Redis;
use BOM::User::Static;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $redis = BOM::Config::Redis::redis_auth_write();
my $oauth = BOM::Database::Model::OAuth->new;
my $brand = Brands->new(name => 'deriv');

## init
my $app_id = do {
    $oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
    $oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
    $oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='Test App'");
    my $app = $oauth->create_app({
        name         => 'Test App',
        user_id      => 1,
        scopes       => ['read', 'trade', 'admin'],
        redirect_uri => 'https://www.example.com/',
    });
    $app->{app_id};
};

## create test user to login
my $email    = 'reactivate1@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr->email($email);
$client_cr->save;
$user->add_client($client_cr);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$client_vr->email($email);
$client_vr->save;
$user->add_client($client_vr);

# mock domain_name to suppress warnings
my $mocked_request = Test::MockModule->new('BOM::Platform::Context::Request');
$mocked_request->mock('domain_name', 'www.binaryqa.com');

# mock is_official_app to app scope confirmation step
my $mock_oath_model = Test::MockModule->new('BOM::Database::Model::OAuth');
$mock_oath_model->mock(is_official_app => sub { return 1 });

sub login {
    my ($t, $email, $password, $csrf_token) = @_;
    $t->post_ok(
        "/authorize?app_id=$app_id&brand=deriv" => form => {
            login      => 1,
            email      => $email,
            password   => $password,
            csrf_token => $csrf_token,
        });
    return $t;
}

sub test_successful_login {
    my ($t, $loginid) = @_;

    is $t->tx->res->dom->at('input[name=csrf_token]'), undef, 'no csrf token';
    is($t->tx->res->error, undef, 'No error') or warn explain $t->tx->res->error;

    my $url = $t->tx->res->headers->location;
    cmp_ok $url, '!~', qr/error/, 'No error in the redirect url';
    like $url, qr/$loginid/, 'Real account loginid appears in the redirect url';
}

sub close_accounts {
    my ($user, $reason, $just_disable) = @_;
    for my $client ($user->clients(include_disabled => 1)) {
        $client->status->clear_disabled;

        $client->status->set('disabled', 'system', $reason);
        $client->status->set('closed',   'system', $reason) unless $just_disable;

        undef $client->{status};
    }
}

my $t = Test::Mojo->new('BOM::OAuth');

subtest 'login fails for disabled accounts' => sub {
    close_accounts($user, 'test', 1);

    $t = $t->get_ok("/authorize?app_id=$app_id&brand=deriv")->content_like(qr/login/);
    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    my $error_message = BOM::User::Static::CONFIG->{errors}->{AccountUnavailable};
    $t = login($t, $email, $password, $csrf_token);
    $t->content_like(qr/$error_message/, 'Correct error messsge when account is disabled from BO');

    is $t->tx->res->dom->at('input[name=csrf_token]')->val, $csrf_token, 'the same csrf token';

    $client_cr->status->clear_disabled;
    $client_vr->status->clear_disabled;
};

subtest 'login fails if activation is cancelled' => sub {
    close_accounts($user, 'test', 1);

    # just CR account is self-closed
    $client_cr->status->set('closed', 'system', 'test');
    is $client_vr->status->closed, undef, 'VR client is not self_closed';

    $t = $t->get_ok("/authorize?app_id=$app_id&brand=deriv")->content_like(qr/login/);
    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    $t = login($t, $email, $password, $csrf_token);
    $t->text_like(
        'html head title' => qr/Log in \| Deriv\.com/,
        'Login page title is expected'
    );
    $t->text_like(
        'p.reactivate-description',
        qr/^\s*By reactivating your account, you agree that we will not be responsible for any losses you incur while trading./,
        "correct reactivation message when account is closed for non-financial reasons"
    );
    ok $t->tx->res->dom->at('button[name=cancel_reactivate]'),  'cancel button';
    ok $t->tx->res->dom->at('button[name=confirm_reactivate]'), 'confirm button';

    $t->post_ok(
        "/authorize?app_id=$app_id&brand=deriv" => form => {
            login             => 1,
            csrf_token        => $csrf_token,
            cancel_reactivate => 1,
        });

    $t->text_unlike(
        'html head title' => qr/Log in \| Deriv\.com/,
        'Login page is left'
    );

    ok $client_cr->status->closed, 'CR account is not reactivated';
    ok $client_cr->status->closed, 'VR account is not reactivated';

    $client_cr->status->clear_disabled;
    $client_vr->status->clear_disabled;
};

subtest 'login succeeds for self-closed accounts' => sub {
    close_accounts($user, 'test', 1);

    # just CR account is self-closed
    $client_cr->status->set('closed', 'system', 'test');
    is $client_vr->status->closed, undef, 'VR client is not self_closed';

    $t = $t->get_ok("/authorize?app_id=$app_id&brand=deriv")->content_like(qr/login/);
    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    $t = login($t, $email, $password, $csrf_token);
    $t->text_like(
        'html head title' => qr/Log in \| Deriv\.com/,
        'Login page title is expected'
    );
    $t->text_like(
        'p.reactivate-description',
        qr/^\s*By reactivating your account, you agree that we will not be responsible for any losses you incur while trading./,
        "correct reactivation message when account is closed for non-financial reasons"
    );
    ok $t->tx->res->dom->at('button[name=cancel_reactivate]'),  'cancel button';
    ok $t->tx->res->dom->at('button[name=confirm_reactivate]'), 'confirm button';

    $t->post_ok(
        "/authorize?app_id=$app_id&brand=deriv" => form => {
            login              => 1,
            csrf_token         => $csrf_token,
            confirm_reactivate => 1,
        });
    test_successful_login($t, $client_cr->loginid);

    undef $client_cr->{status};    # let status reloaded
    is $client_cr->status->disabled, undef, 'Self-closed accoount is enabled';
    is $client_cr->status->closed,   undef, 'Self-closed accoount is reactivated';

    undef $client_vr->{status};    # let status reloaded
    ok $client_vr->status->disabled, 'VR sibling is still disabled';
};

subtest 'reactivation - closed for financial concerns' => sub {
    close_accounts($user, 'financial concerns');

    $t = $t->get_ok("/authorize?app_id=$app_id&brand=deriv")->content_like(qr/login/);
    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    $t = login($t, $email, $password, $csrf_token);

    $t->text_like(
        'p.reactivate-description',
        qr/^\s*You deactivated your account due to financial reasons.\s*By reactivating your account, you agree that we will not be responsible for any losses you incur while trading./,
        "correct reactivation message when account is closed for financial reasons"
    );
    ok $t->tx->res->dom->at('button[name=cancel_reactivate]'),  'cancel button';
    ok $t->tx->res->dom->at('button[name=confirm_reactivate]'), 'confirm button';

    $t->post_ok(
        "/authorize?app_id=$app_id&brand=deriv" => form => {
            login              => 1,
            csrf_token         => $csrf_token,
            confirm_reactivate => 1,
        });
    test_successful_login($t, $client_cr->loginid);

    undef $client_cr->{status};
    undef $client_vr->{status};
    is $client_cr->status->disabled, undef, 'CR client is enabled';
    is $client_cr->status->closed,   undef, 'CR client is reactivated';
    is $client_vr->status->disabled, undef, 'VR client is enabled';
    is $client_vr->status->closed,   undef, 'VR client is enabled';
};

subtest 'social responsibility email' => sub {
    my $email_mlt = 'reactivate_mlt@binary.com';
    my $user_mlt  = BOM::User->create(
        email    => $email_mlt,
        password => $hash_pwd
    );

    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $client_mlt->email($email_mlt);
    $client_mlt->save;
    $user_mlt->add_client($client_mlt);

    close_accounts($user_mlt, 'test');

    $t = $t->get_ok("/authorize?app_id=$app_id&brand=deriv")->content_like(qr/login/);
    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';

    $t = login($t, $email_mlt, $password, $csrf_token);
    ok $t->tx->res->dom->at('button[name=cancel_reactivate]'),  'cancel button';
    ok $t->tx->res->dom->at('button[name=confirm_reactivate]'), 'confirm button';
    $t->post_ok(
        "/authorize?app_id=$app_id&brand=deriv" => form => {
            login              => 1,
            csrf_token         => $csrf_token,
            confirm_reactivate => 1,
        });
    test_successful_login($t, $client_mlt->loginid);
};

done_testing();

use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Authen::OATH;
use BOM::User::Password;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Config::RedisReplicated;

my $redis = BOM::Config::RedisReplicated::redis_auth_write();

## init
my $app_id = do {
    my $oauth = BOM::Database::Model::OAuth->new;
    $oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
    $oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
    $oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='Test App'");
    my $app = $oauth->create_app({
        name         => 'Test App',
        user_id      => 1,
        scopes       => ['read', 'trade', 'admin'],
        redirect_uri => 'https://www.example.com/'
    });
    $app->{app_id};
};

## create test user to login
my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';

my $hash_pwd  = BOM::User::Password::hashpw($password);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr->email($email);
$client_cr->save;
my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($client_cr);

$redis->del("CLIENT_LOGIN_HISTORY::" . $user->id);

# mock domain_name to suppress warnings
my $mocked_request = Test::MockModule->new('BOM::Platform::Context::Request');
$mocked_request->mock('domain_name', 'www.binaryqa.com');

# mock send email
my $virtual_inbox = [];
my $platform_mock = Test::MockModule->new('BOM::Platform::Email');
$platform_mock->mock(
    'send_email',
    sub {
        push @$virtual_inbox, "email sent";
    });

sub do_client_login {
    my $agent        = shift // 'chrome';
    my $agent_header = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.79 Safari/537.36';
    my $t            = Test::Mojo->new('BOM::OAuth');

    if ($agent eq 'firefox') {
        $agent_header = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Firefox/79.0.3945.79 Safari/537.36';
    }

    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('User-Agent' => $agent_header);
        });

    $t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';
    $t->post_ok(
        "/authorize?app_id=$app_id" => form => {
            login      => 1,
            email      => $email,
            password   => $password,
            csrf_token => $csrf_token
        });

}

subtest "it should not send an email for first time login" => sub {
    do_client_login();
    is(scalar @$virtual_inbox, 0, 'email should not be sent for first login');
};

subtest "it should send an email if login is unknown" => sub {
    do_client_login('firefox');
    is(scalar @$virtual_inbox, 1, 'email should have been sent if attempt is unknown');
};

subtest "it should not send an email if login is known" => sub {
    # clear the virtual inbox
    $virtual_inbox = [];
    do_client_login('firefox');
    is(scalar @$virtual_inbox, 0, 'email should not be sent for first login');
};

subtest "it should not send an email if no entry but we have a previous recored in the DB" => sub {
    # clear the virtual inbox
    $virtual_inbox = [];
    # clear redis
    $redis->del("CLIENT_LOGIN_HISTORY::" . $user->id);
    do_client_login();
    is(scalar @$virtual_inbox, 1, 'email should be sent for new unknown logins');
};

done_testing()

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
use BOM::Config::Redis;

my $redis = BOM::Config::Redis::redis_auth_write();

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

my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
$emitter_mock->mock(
    'emit',
    sub {
        push(@$virtual_inbox, "event emitted") if shift =~ "unknown_login";
    });

sub do_client_login {
    my $agent        = shift // 'chrome';
    my $brand        = shift // 'binary';
    my $agent_header = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.79 Safari/537.36';
    my $t            = Test::Mojo->new('BOM::OAuth');
    $email    = shift // $email;
    $password = shift // $password;
    my $device_id = shift;

    if ($agent eq 'firefox') {
        $agent_header = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Firefox/79.0.3945.79 Safari/537.36';
    }

    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('User-Agent' => $agent_header);
        });

    my $url = "/authorize?app_id=$app_id&brand=$brand";
    $url .= "&device_id=$device_id" if $device_id;

    $t = $t->get_ok($url)->content_like(qr/login/);

    my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
    ok $csrf_token, 'csrf_token is there';
    $t->post_ok(
        $url => form => {
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

subtest "it should not send any notification email for new login if brand is deriv" => sub {
    my $email    = 'deriv_randomly_email_address@deriv.com';
    my $password = BOM::User::Password::hashpw('alkdjasldkjaslkxjclk');

    BOM::User->create(
        email    => $email,
        password => $password
    );

    $virtual_inbox = [];
    do_client_login('firefox', 'deriv', $email, $password);
    is(scalar @$virtual_inbox, 0, 'email should not be sent for deriv first login.');

    do_client_login('firefox', 'deriv', $email, $password);
    is(scalar @$virtual_inbox, 0, 'email should not be sent for deriv at all.');
};

# Test Scenario Matrix 1
# S/No.  Signup  Login  Device ID             Trigger Email  Remark
# -----------------------------------------------------------------------
# 1      Yes     -      Yes (New device)      No             User signup with device information
# 2      -       Yes    No                    Yes            User signup with device information but logged in without device
# 3      -       Yes    Yes (existing device) No             As attempt is known
# 4      -       Yes    Yes (changed device)  Yes            Device information changed

$email    = 'user1@binary.com';
$password = 'jskjd8292922';

subtest "User signup with device information" => sub {
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

    do_client_login('firefox', 'deriv', $email, $password, 'newdeviceid');
    is(scalar @$virtual_inbox, 0, 'email should not be sent for first login with device information.');
};

subtest "User login without device information" => sub {
    $virtual_inbox = [];
    do_client_login('firefox', 'deriv', $email, $password);
    is(scalar @$virtual_inbox, 1, 'email should be sent for as device information removed.');
};

subtest "User login with existing device information" => sub {
    $virtual_inbox = [];
    do_client_login('firefox', 'deriv', $email, $password, 'newdeviceid');
    is(scalar @$virtual_inbox, 0, 'email should not sent for same device information.');
};

subtest "User login with changed device information" => sub {
    $virtual_inbox = [];
    do_client_login('firefox', 'deriv', $email, $password, 'newdeviceidhh');
    is(scalar @$virtual_inbox, 1, 'email should be sent for changed device information.');
};

# Test Scenario Matrix 2
# S/No. Signup  Login  Device ID             Trigger Email  Remark
# --------------------------------------------------------------------
# 1     Yes     -      No                    No             No device rgistered during signup
# 2     -       Yes    No                    No             Login without device information
# 3     -       Yes    Yes (New device)      No             First time new device is used - ignored
# 4     -       Yes    No                    No             As without device, his last login (point 2) attempt was known, so ignored
# 5     -       Yes    Yes (existing device) No             As he used the same previously used device, attempt known
# 6     -       Yes    Yes (changed device)  Yes            As he used the new device, email triggered

$email    = 'user2@binary.com';
$password = 'jskjd8292922';

subtest "User2 signup without device information" => sub {
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

    $virtual_inbox = [];
    do_client_login('firefox', 'deriv', $email, $password);
    is(scalar @$virtual_inbox, 0, 'email should not be sent for first login without device information.');
};

subtest "User2 login without device information " => sub {
    do_client_login('firefox', 'deriv', $email, $password);
    is(scalar @$virtual_inbox, 0, 'email should not be sent for without device information.');
};

subtest "User2 login with new device information" => sub {
    $virtual_inbox = [];
    do_client_login('firefox', 'deriv', $email, $password, 'newdeviceidhh');
    is(scalar @$virtual_inbox, 0, 'email should not sent first time new device is used.');
};

subtest "User2 login again without device information " => sub {
    do_client_login('firefox', 'deriv', $email, $password);
    is(scalar @$virtual_inbox, 0, 'email should not be sent attempt is known.');
};

subtest "User2 login with existing device information" => sub {
    do_client_login('firefox', 'deriv', $email, $password, 'newdeviceidhh');
    is(scalar @$virtual_inbox, 0, 'email should not be sent as attempt is known.');
};

subtest "User2 login with changed device information" => sub {
    do_client_login('firefox', 'deriv', $email, $password, 'newdevice');
    is(scalar @$virtual_inbox, 1, 'email should be sent as attempt is new device.');
};

done_testing()

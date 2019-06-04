use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use BOM::User::Password;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;
use BOM::Config::Runtime;
use BOM::User::TOTP;
use BOM::Platform::Email qw(send_email);
use Email::Sender::Transport::Test;
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
my $email      = 'abc@binary.com';
my $password   = 'jskjd8292922';
my $secret_key = BOM::User::TOTP->generate_key();
my $hash_pwd   = BOM::User::Password::hashpw($password);
my $client_cr  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr->email($email);
$client_cr->save;
my $cr_loginid = $client_cr->loginid;
my $user       = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($client_cr);
$user->update_totp_fields(
    secret_key      => $secret_key,
    is_totp_enabled => 1
);

my $t = Test::Mojo->new('BOM::OAuth');

# mock domain_name to suppress warnings
my $mocked_request = Test::MockModule->new('BOM::Platform::Context::Request');
$mocked_request->mock('domain_name', 'www.binaryqa.com');

$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';

$t = callPost($t, "", $password, $csrf_token, "ID");
$t = $t->content_like(qr/Email belum diberikan./, "no email ID");

$t = callPost($t, $email, "", $csrf_token, "ID");
$t = $t->content_like(qr/Kata sandi tidak diberikan./, "no password ID");

$t = callPost($t, $email . "invalid", $password, $csrf_token, "ID");
$t = $t->content_like(qr/Email atau kata sandi salah. Mohon periksa apakah Anda sebelumnya mengakses melalui jejaring sosial./,
    "invalid login or password iID");

$user->update_has_social_signup(1);

$t = callPost($t, $email, $password, $csrf_token, "ID");
$t = $t->content_like(qr/Email atau kata sandi salah. Mohon periksa apakah Anda sebelumnya mengakses melalui jejaring sosial./,
    "invalid social login ID");

$user->update_has_social_signup(0);

BOM::Config::Runtime->instance->app_config->system->suspend->all_logins(1);

$t = callPost($t, $email, $password, $csrf_token, "ID");
$t = $t->content_like(qr/Maaf, Transfer Agen Pembayaran dihentikan untuk sementara berhubung perbaikan sistem. Silahkan coba kembali 30 menit lagi./,
    "temp disabled ID");

BOM::Config::Runtime->instance->app_config->system->suspend->all_logins(0);

my $mock_session = Test::MockModule->new('BOM::Database::Model::OAuth');
$mock_session->mock(
    'has_other_login_sessions' => sub {
        return 1;
    });

my $mock_history = Test::MockModule->new('BOM::User');
$mock_history->mock(
    'get_last_successful_login_history' => sub {
        return {"environment" => "IP=1.1.1.1 IP_COUNTRY=1.1.1.1 User_AGENT=ABC LANG=AU"};
    });

BEGIN { use_ok('BOM::Platform::Email', qw(send_email)); }

my $transport      = Email::Sender::Transport::Test->new;
my $mocked_stuffer = Test::MockModule->new('Email::Stuffer');

$mocked_stuffer->mock(
    'send_or_die',
    sub {
        my $self = shift;
        $self->transport($transport);
        $mocked_stuffer->original('send_or_die')->($self, @_);
    });

$t = callPost($t, $email, $password, $csrf_token, "ID");
my @deliveries = $transport->deliveries;
my $semail     = $deliveries[-1]{email};
# this test can be added back when we have an updated translation
# like($semail->get_header('Subject'), qr/Aktivitas Pengaksesan Baru Terdeteksi/, "email subject ID validation");
like($semail->get_body, qr/$email|ID/i, "email ID validation");

done_testing();

sub callPost {
    my ($t, $email, $password, $csrf_token, $lang) = @_;

    # mock language
    my $mock = Test::MockModule->new('BOM::Platform::Context::I18N');
    $mock->mock(
        'handle_for' => sub {
            return Locale::Maketext::ManyPluralForms->get_handle($lang);
        });

    $t->post_ok(
        "/authorize?app_id=$app_id&l=$lang" => form => {
            login      => 1,
            email      => $email,
            password   => $password,
            csrf_token => $csrf_token,
        });
    return $t;
}


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
$user->save;
$user->add_loginid({loginid => $cr_loginid});
$user->secret_key($secret_key);
$user->is_totp_enabled(1);
$user->save;

my $t = Test::Mojo->new('BOM::OAuth');

# mock domain_name to suppress warnings
my $mocked_request = Test::MockModule->new('BOM::Platform::Context::Request');
$mocked_request->mock('domain_name', 'www.binaryqa.com');

$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';

$t = callPost($t, "", $password, $csrf_token, "ES");
$t = $t->content_like(qr/No nos ha facilitado su email./, "no email ES");
$t = callPost($t, "", $password, $csrf_token, "PT");
$t = $t->content_like(qr/E-mail não fornecido./, "no email PT");

$t = callPost($t, $email, "", $csrf_token, "ES");
$t = $t->content_like(qr/No se ha escrito ninguna contraseña./, "no password ES");
$t = callPost($t, $email, "", $csrf_token, "PT");
$t = $t->content_like(qr/Senha não dada./, "no password PT");

$t = callPost($t, $email . "invalid", $password, $csrf_token, "ES");
$t = $t->content_like(qr/Contraseña o email incorrecto./, "invalid login or password iES");
$t = callPost($t, $email . "invalid", $password, $csrf_token, "PT");
$t = $t->content_like(qr/E-mail ou senha incorreta./, "invalid login or password PT");

$user->has_social_signup(1);
$user->save;

$t = callPost($t, $email, $password, $csrf_token, "ES");
$t = $t->content_like(qr/Intento de inicio de sesión inválido. Conéctese a través de una red social en su lugar./, "invalid social login ES");
$t = callPost($t, $email, $password, $csrf_token, "PT");
$t = $t->content_like(qr/Tentativa de login inválida. Conecte-se antes através de uma rede./, "invalid social login PT");

$user->has_social_signup(0);
$user->save;

BOM::Config::Runtime->instance->app_config->system->suspend->all_logins(1);

$t = callPost($t, $email, $password, $csrf_token, "ES");
$t = $t->content_like(
    qr/El acceso a esta cuenta está temporalmente desactivado por cuestiones de mantenimiento.  Inténtelo nuevamente dentro de 30 minutos./,
    "temp disabled ES");
$t = callPost($t, $email, $password, $csrf_token, "PT");
$t = $t->content_like(
    qr/Os acessos às contas estão temporariamente suspensos devido à manutenção do sistema. Por favor, tente novamente em 30 minutos./,
    "temp disabled PT");

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

$t = callPost($t, $email, $password, $csrf_token, "ES");
my @deliveries = $transport->deliveries;
my $semail     = $deliveries[-1]{email};
like($semail->get_header('Subject'), qr/Nueva Actividad de Inicio de Sesión Detectada/, "email subject ES validation");
like($semail->get_body, qr/$email|ES/i, "email ES validation");

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


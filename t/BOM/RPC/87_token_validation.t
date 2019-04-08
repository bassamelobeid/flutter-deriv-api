use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;
use utf8;
use BOM::Platform::Token;
use BOM::Config::Runtime;
use Email::Stuffer::TestLinks;

my $email_cr = 'abc@binary.com';
my $dob      = '1990-07-09';

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code   => 'CR',
    date_of_birth => '1990-07-09'
});
$client_cr->email($email_cr);
$client_cr->status->set('tnc_approval', 'system', BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version);
$client_cr->set_default_account('USD');
$client_cr->save;

my $user_cr = BOM::User->create(
    email    => $email_cr,
    password => BOM::User::Password::hashpw('jskjd8292922'));
$user_cr->add_client($client_cr);

my $code = BOM::Platform::Token->new({
        email       => $email_cr,
        expires_in  => 3600,
        created_for => 'reset_password'
    })->token;

my $params = {
    args => {
        cashier           => 'withdraw',
        verification_code => $code
    }};

my ($t, $c);
subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
        $c = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

$params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');

$c->call_ok('cashier', $params)
    ->has_no_system_error->has_error->error_code_is('InvalidToken', 'Reset password token can not be used for cashier withdrawal')
    ->error_message_is('Your token has expired or is invalid.', 'Correct error message for token invalid');

done_testing();

use strict;
use warnings;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;

use BOM::User;
use utf8;
use BOM::Platform::Token;
use Email::Stuffer::TestLinks;

my $mock_client = Test::MockModule->new('BOM::User::Client');
$mock_client->mock('is_tnc_approval_required', sub { return 0; });

my $email_cr = 'abc@binary.com';
my $dob      = '1990-07-09';

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code   => 'CR',
    date_of_birth => '1990-07-09'
});
$client_cr->email($email_cr);
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
#create 2nd client
my $email_cr_2  = 'cr2_abc@binary.com';
my $client_cr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code   => 'CR',
    date_of_birth => '1990-07-09'
});
$client_cr_2->email($email_cr_2);
$client_cr_2->set_default_account('USD');
$client_cr_2->save;

my $user_cr_2 = BOM::User->create(
    email    => $email_cr_2,
    password => BOM::User::Password::hashpw('jskjd8292922'));
$user_cr_2->add_client($client_cr_2);

my $code_cr_2 = BOM::Platform::Token->new({
        email       => $email_cr_2,
        expires_in  => 3600,
        created_for => 'payment_withdraw'
    })->token;

my $params = {
    args => {
        cashier           => 'withdraw',
        verification_code => $code
    }};

my $c;
subtest 'Initialization' => sub {
    lives_ok {
        $c = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

$params->{token} = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token');

$c->call_ok('cashier', $params)
    ->has_no_system_error->has_error->error_code_is('InvalidToken', 'Reset password token can not be used for cashier withdrawal')
    ->error_message_is('Your token has expired or is invalid.', 'Correct error message for token invalid');

$params->{token} = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token');

$params->{args}->{verification_code} = $code_cr_2;
$c->call_ok('cashier', $params)
    ->has_no_system_error->has_error->error_code_is('InvalidToken', 'Error code is correct when one client used other client withdrawal token.')
    ->error_message_is('Your token has expired or is invalid.',
    'Correct error message for token invalid when one client used other client withdrawal token.');

done_testing();

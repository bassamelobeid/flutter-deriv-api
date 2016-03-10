use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Email qw(get_email_by_address_subject clear_mailbox);

use utf8;

my ( $user, $client, $email );
my ( $t, $rpc_ct );
my $method;

my $params = {
    language => 'RU',
    source => 1,
    country => 'ru',
    args => {},
};

subtest 'Initialization' => sub {
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $email = 'test@binary.com';
    } 'Initial client';

    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );
    } 'Initial RPC server and client connection';
};

$method = 'new_account_virtual';
subtest $method => sub {
    $params->{args}->{client_password} = '123';
    $params->{args}->{email} = $email;
    $params->{args}->{verification_code} = 'wrong token';

    $rpc_ct->call_ok($method, $params)
            ->has_no_system_error
            ->has_error
            ->error_code_is('Password is not strong enough.', 'If password is weak it should return error')
            ->error_message_is('Пароль недостаточно надёжный.', 'If password is weak it should return error_message');

    $params->{args}->{client_password} = 'verylongandhardpasswordDDD1!';
    $rpc_ct->call_ok($method, $params)
            ->has_no_system_error
            ->has_error
            ->error_code_is('email unverified', 'If email verification_code is wrong it should return error')
            ->error_message_is('Ваш электронный адрес не подтвержден.', 'If email verification_code is wrong it should return error_message');

};

done_testing();

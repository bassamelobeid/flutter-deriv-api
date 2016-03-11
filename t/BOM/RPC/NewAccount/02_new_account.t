use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;

use utf8;

my $email = 'test'. rand(999) .'@binary.com';
my ( $t, $rpc_ct );
my ( $method, $params );

$params = {
    language => 'RU',
    source => 1,
    country => 'ru',
    args => {},
};

subtest 'Initialization' => sub {
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
            ->error_code_is('ChangePasswordError', 'If password is weak it should return error')
            ->error_message_is('Пароль недостаточно надёжный.', 'If password is weak it should return error_message');

    $params->{args}->{client_password} = 'verylongandhardpasswordDDD1!';
    $rpc_ct->call_ok($method, $params)
            ->has_no_system_error
            ->has_error
            ->error_code_is('email unverified', 'If email verification_code is wrong it should return error')
            ->error_message_is('Ваш электронный адрес не подтвержден.', 'If email verification_code is wrong it should return error_message');

    $params->{args}->{verification_code} =
        BOM::Platform::SessionCookie->new(
            email => $email,
        )->token;
    $rpc_ct->call_ok($method, $params)
            ->has_no_system_error
            ->has_error
            ->error_code_is('invalid', 'If could not be created account it should return error')
            ->error_message_is('Извините, но открытие счёта недоступно.', 'If could not be created account it should return error_message');

    $params->{args}->{verification_code} =
        BOM::Platform::SessionCookie->new(
            email => $email,
        )->token;
    $params->{args}->{residence} = 'id';
    $rpc_ct->call_ok($method, $params)
            ->has_no_system_error
            ->has_no_error('If verification code is ok - account created successfully');

    is_deeply   [sort keys %{ $rpc_ct->result }],
                [sort qw/ currency balance client_id /],
                'It should return new account data';
};

$method = 'new_account_real';
$params = {
    language => 'RU',
    source => 1,
    country => 'ru',
    args => {},
};

subtest $method => sub {
    my ( $user, $client, $vclient, $auth_token, $session );

    subtest 'Initialization' => sub {
        lives_ok {
            # Make real client
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email => 'new_email' . rand(999) . '@binary.com',
            });
            $auth_token = BOM::Database::Model::AccessToken->new->create_token( $client->loginid, 'test token' );
            $session = BOM::Platform::SessionCookie->new(
                loginid => $client->loginid,
                email   => $client->email,
            )->token;

            # Make virtual client with user
            my $password = 'jskjd8292922';
            my $hash_pwd = BOM::System::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user = BOM::Platform::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $user->save;

            $vclient = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email => $email,
            });

            $user->add_loginid({loginid => $vclient->loginid});
            $user->save;
        } 'Initial users and clients';
    };

    subtest 'Auth client' => sub {
        $rpc_ct->call_ok($method, $params)
               ->has_no_system_error
               ->error_code_is( 'InvalidToken',
                                'It should return error: InvalidToken' );

        $params->{token} = 'wrong token';
        $rpc_ct->call_ok($method, $params)
               ->has_no_system_error
               ->error_code_is( 'InvalidToken',
                                'It should return error: InvalidToken' );

        delete $params->{token};
        $rpc_ct->call_ok($method, $params)
               ->has_no_system_error
               ->error_code_is( 'InvalidToken',
                                'It should return error: InvalidToken' );

        $params->{token} = $auth_token;

        {
            my $module = Test::MockModule->new('BOM::Platform::Client');
            $module->mock( 'new', sub {} );

            $rpc_ct->call_ok($method, $params)
                  ->has_no_system_error
                  ->has_error
                  ->error_code_is( 'AuthorizationRequired', 'It should check auth' );
        }
    };

    subtest 'Create new account' => sub {
        $rpc_ct->call_ok($method, $params)
              ->has_no_system_error
              ->has_error
              ->error_code_is('invalid', 'It should return error when try to create acc to real client')
              ->error_message_is('Извините, но открытие счёта недоступно.',
                                 'It should return error when try to create acc to real client');

        $params->{token} = BOM::Database::Model::AccessToken->new->create_token( $vclient->loginid, 'test token' );
        $rpc_ct->call_ok($method, $params)
              ->has_no_system_error
              ->has_error
              ->error_code_is('invalid', 'It should return error when try to create account without residence')
              ->error_message_is('Извините, но открытие счёта недоступно.',
                                 'It should return error when try to create account without residence');

        $params->{args}->{residence} = 'id';
        $params->{args}->{salutation} = 'hello';
        $params->{args}->{last_name} = 'Vostrov' . rand(999);
        $params->{args}->{date_of_birth} = '1987-09-04';
        $params->{args}->{address_line_1} = 'Sovetskaya street';
        $params->{args}->{address_line_2} = 'home 1';
        $params->{args}->{address_city} = 'Samara';
        $params->{args}->{address_state} = 'Samara';
        $params->{args}->{address_postcode} = '112233';
        $params->{args}->{phone} = '+79272075932';
        $params->{args}->{secret_question} = 'test';
        $params->{args}->{secret_answer} = 'test';

        $rpc_ct->call_ok($method, $params)
              ->has_no_system_error
              ->has_error
              ->error_code_is('invalid', 'It should return error if missing any details')
              ->error_message_is('Извините, но открытие счёта недоступно.',
                                 'It should return error if missing any details');

        $params->{args}->{first_name} = 'Evgeniy' . rand(999);
        $rpc_ct->call_ok($method, $params)
              ->has_no_system_error
              ->has_error
              ->error_code_is('email unverified', 'It should return error if email unverified')
              ->error_message_is('Ваш электронный адрес не подтвержден.',
                                 'It should return error if email unverified');

        $user->email_verified(1);
        $user->save;
        $rpc_ct->call_ok($method, $params)
                ->has_no_system_error
                ->has_no_error;
        is_deeply   [sort keys %{$rpc_ct->result}],
                    [sort qw/ landing_company landing_company_shortcode client_id /],
                    'It should return new client data if creation ended successfully';
    };

};

done_testing();

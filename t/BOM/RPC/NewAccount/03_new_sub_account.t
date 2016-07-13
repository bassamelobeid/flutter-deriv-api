use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use POSIX qw/ ceil /;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Token;
use BOM::Platform::Client;

use utf8;

my $email = 'test' . rand(999) . '@binary.com';
my ($t, $rpc_ct);
my ($method, $params, $client_details);

$client_details = {
    salutation       => 'Mr',
    last_name        => 'Kathuria' . rand(999),
    first_name       => 'Raunak' . rand(999),
    date_of_birth    => '1986-09-04',
    address_line_1   => '3D Street',
    address_line_2   => 'home 1',
    address_city     => 'Faridabad',
    address_state    => 'Haryana',
    address_postcode => '122233',
    phone            => '+91972075932',
    secret_question  => 'test',
    secret_answer    => 'test',
};

$params = {
    language => 'EN',
    source   => 1,
    country  => 'in',
    args     => {},
};

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = Test::BOM::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

$method = 'new_sub_account';
subtest $method => sub {
    my ($user, $client, $vclient, $auth_token);

    subtest 'Initialization' => sub {
        lives_ok {
            # Make real client
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email       => 'new_email' . rand(999) . '@binary.com',
            });
            $auth_token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');

            # Make virtual client with user
            my $password = 'jskjd8292922';
            my $hash_pwd = BOM::System::Password::hashpw($password);
            $email = 'new_email' . rand(999) . '@binary.com';
            $user  = BOM::Platform::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $user->save;

            $vclient = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'VRTC',
                email       => $email,
            });

            $user->add_loginid({loginid => $vclient->loginid});
            $user->save;
        }
        'Initial users and clients';
    };

    subtest 'Create new account' => sub {
        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($vclient->loginid, 'test token');
        $params->{args}->{residence} = 'id';

        $rpc_ct->call_ok('new_sub_account', $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied', 'Virtual account cannot create sub account');

        @{$params->{args}}{keys %$client_details} = values %$client_details;
        $user->email_verified(1);
        $user->save;
        $rpc_ct->call_ok('new_account_real', $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Binary (C.R.) S.A.',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'costarica', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';

        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($new_loginid, 'test real account token');
        $rpc_ct->call_ok('new_sub_account', $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied', 'Allow omnibus flag needs to be set to create sub account');

        my $real_client = BOM::Platform::Client->new({loginid => $new_loginid});
        $real_client->allow_omnibus(1);
        $real_client->save();
        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($real_client->loginid, 'real account token');
        $rpc_ct->call_ok('new_sub_account', $params)->has_no_system_error->has_error->error_code_is('duplicate name DOB',
            'as details are provided so we will not populate with default values, hence duplicate error');
    };

};

done_testing();

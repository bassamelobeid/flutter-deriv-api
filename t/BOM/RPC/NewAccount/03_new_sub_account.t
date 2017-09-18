use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::FailWarnings;
use Test::Warn;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use POSIX qw/ ceil /;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Token;
use Client::Account;

use utf8;

my ($email, $t, $rpc_ct) = ('test' . rand(999) . '@binary.com');

my $client_details = {
    salutation             => 'Mr',
    last_name              => 'Kathuria' . rand(999),
    first_name             => 'Raunak' . rand(999),
    date_of_birth          => '1986-09-04',
    address_line_1         => '3D Street',
    address_line_2         => 'home 1',
    address_city           => 'Faridabad',
    address_state          => 'Haryana',
    address_postcode       => '122233',
    phone                  => '+91972075932',
    secret_question        => 'test',
    secret_answer          => 'test',
    account_opening_reason => 'Income Earning',
};

my $params = {
    language => 'EN',
    source   => 1,
    country  => 'in',
    args     => {},
};

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

my $method = 'new_sub_account';
subtest $method => sub {
    my ($user, $client, $vclient, $real_client, $sub_client, $token);

    subtest 'Initialization' => sub {
        lives_ok {
            # Make real client
            $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email       => 'new_email' . rand(999) . '@binary.com',
            });

            # Make virtual client with user
            my $password = 'jskjd8292922';
            my $hash_pwd = BOM::Platform::Password::hashpw($password);
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

        $token = BOM::Database::Model::AccessToken->new->create_token($new_loginid, 'test real account token');
        $params->{token} = $token;
        $rpc_ct->call_ok('new_sub_account', $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied', 'Allow omnibus flag needs to be set to create sub account');

        $real_client = Client::Account->new({loginid => $new_loginid});
        $real_client->allow_omnibus(1);
        $real_client->save();
        my $result = $rpc_ct->call_ok('new_sub_account', $params)->has_no_system_error->result;
        is $result->{landing_company}, 'Binary (C.R.) S.A.', 'Landing company same as master account for sub account with details';

        # empty all details so that we default details to master account
        $params->{args} = {new_sub_account => 1};
        $result = $rpc_ct->call_ok('new_sub_account', $params)->has_no_system_error->result;
        is $result->{landing_company}, 'Binary (C.R.) S.A.', 'Landing company same as master account';

        my $sub_account_loginid = $result->{client_id};
        ok $sub_account_loginid =~ /^CR\d+$/, 'new CR sub account loginid';

        $sub_client = Client::Account->new({loginid => $sub_account_loginid});
        is $sub_client->sub_account_of, $new_loginid, 'Correct loginid populated for sub_account_of for sub account';
        is $sub_client->email,         $real_client->email,         'Email for master and sub account is same';
        is $sub_client->date_of_birth, $real_client->date_of_birth, 'Date of birth for master and sub account is same';

        is $sub_client->first_name,     $real_client->first_name,     "First name of sub account is same as master if details are not provided";
        is $sub_client->last_name,      $real_client->last_name,      "Last name of sub account is same as master if details are not provided";
        is $sub_client->address_line_1, $real_client->address_line_1, 'same address as master account';
    };

    my ($result, $sub_token);
    subtest 'Api token for sub account' => sub {
        $params = {
            language => 'EN',
            source   => 1,
            country  => 'in',
            token    => $token,
            args     => {
                new_token        => 'Test Token',
                new_token_scopes => ['read', 'trade'],
                sub_account      => $sub_client->loginid,
            },
        };
        $result = $rpc_ct->call_ok('api_token', $params)->has_no_system_error->result;

        $sub_token = $result->{tokens}->[0]->{token};
        is $result->{sub_account}, $sub_client->loginid, 'token has correct sub account';
        is $result->{tokens}->[0]->{display_name}, 'Test Token', 'token has correct name';
        is_deeply([sort @{$result->{tokens}->[0]->{scopes}}], ['read', 'trade'], 'right scopes');
    };

    subtest 'Authorize' => sub {
        $params = {
            language => 'EN',
            token    => $sub_token
        };
        $result = $rpc_ct->call_ok('authorize', $params)->has_no_system_error->result;
        is scalar @{$result->{sub_accounts}}, 0, 'Sub account cant have sub accounts';
        is $result->{allow_omnibus}, 0, 'Allow omnibus not set for sub account';

        $params->{token} = $token;
        $result = $rpc_ct->call_ok('authorize', $params)->has_no_system_error->result;
        is $result->{allow_omnibus}, 1, 'Allow omnibus set';
        is scalar @{$result->{sub_accounts}}, 2, 'Correct number of sub accounts';
        my $match = grep { $_->{loginid} eq $sub_client->loginid } @{$result->{sub_accounts}};
        ok $match, 'Correct sub account for omnibus';
        is_deeply([sort keys %{$result->{sub_accounts}->[0]}], ['currency', 'loginid'], 'correct structure');
    };

    subtest 'Payout currencies' => sub {
        $params = {
            language => 'EN',
        };
        $result = $rpc_ct->call_ok('payout_currencies', $params)->has_no_system_error->result;
        is scalar @$result, 7, 'Correct number of currencies when token is not passed';

        $params->{token} = $token;
        $result = $rpc_ct->call_ok('payout_currencies', $params)->has_no_system_error->result;
        is scalar @$result, 7, 'Correct number of currencies for omnibus if authorized as currency not yet selected';

        $params->{token} = $sub_token;
        $result = $rpc_ct->call_ok('payout_currencies', $params)->has_no_system_error->result;
        is scalar @$result, 7, 'Correct number of currencies when sub account token is passed as currency not yet selected';
    };

};

done_testing();

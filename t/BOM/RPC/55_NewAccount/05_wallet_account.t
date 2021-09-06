use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep qw(cmp_deeply);
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;
use Test::Fatal qw(lives_ok);

use MojoX::JSON::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token;
use BOM::User::Client;
use BOM::User::Wallet;
use BOM::Database::Model::OAuth;
use BOM::Platform::Token::API;

use utf8;

my $rpc_ct;
subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

my $method = 'new_account_virtual';

subtest 'virtual account' => sub {

    subtest 'create VRTC, then add VRDW' => sub {
        my $email = 'trading@binary.com';

        my $params = {};
        $params->{args}->{residence}         = 'id';
        $params->{args}->{client_password}   = 'pWd12345';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('account created successfully');
        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^VRTC\d+/, 'new VRTC loginid';

        BOM::Config::Runtime->instance->app_config->system->suspend->wallets(0);

        $params->{args}->{type} = 'wallet';
        delete $params->{args}->{verification_code};

        # bad token
        $params->{token} = BOM::Platform::Token::API->new->create_token($new_loginid, 'test token', ['read']);
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidToken')
            ->error_message_is("The token is invalid, requires 'admin' scope.");

        $params->{token} = BOM::Platform::Token::API->new->create_token($new_loginid, 'test token', ['admin']);

        # invalid request params
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidRequestParams')
            ->error_message_is("Invalid request parameters.");

        delete $params->{args}->{residence};
        delete $params->{args}->{client_password};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('account created successfully');
        $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^VRDW\d+/, 'new VRDW loginid';
    };

    subtest 'create VRDW, then add VRTC' => sub {
        my $email = 'wallet@binary.com';

        my $params = {};
        $params->{args}->{type} = 'wallet';

        $params->{args}->{residence}         = 'id';
        $params->{args}->{client_password}   = 'pWd12345';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('account created successfully');
        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^VRDW\d+/, 'new VRDW loginid';

        BOM::Config::Runtime->instance->app_config->system->suspend->wallets(0);

        $params->{args}->{type} = 'trading';
        delete $params->{args}->{verification_code};

        # bad token
        $params->{token} = BOM::Platform::Token::API->new->create_token($new_loginid, 'test token', ['read']);
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidToken')
            ->error_message_is("The token is invalid, requires 'admin' scope.");

        $params->{token} = BOM::Platform::Token::API->new->create_token($new_loginid, 'test token', ['admin']);

        # invalid request params
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidRequestParams')
            ->error_message_is("Invalid request parameters.");

        delete $params->{args}->{residence};
        delete $params->{args}->{client_password};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('account created successfully');
        $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^VRTC\d+/, 'new VRTC loginid';
    };

    subtest 'suspend wallet' => sub {
        my $email = 'testsuspend@binary.com';

        my $params = {};
        $params->{args}->{type} = 'wallet';

        $params->{args}->{residence}         = 'id';
        $params->{args}->{client_password}   = 'pWd12345';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('PermissionDenied')
            ->error_message_is("Wallet account creation is currently suspended.");

        BOM::Config::Runtime->instance->app_config->system->suspend->wallets(0);
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('account created successfully');
        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^VRDW\d+/, 'new VRDW loginid';

        subtest 'duplicate wallet' => sub {
            delete $params->{args}->{residence};
            delete $params->{args}->{client_password};
            delete $params->{args}->{verification_code};

            $params->{token} = BOM::Platform::Token::API->new->create_token($new_loginid, 'test token', ['admin']);

            $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('DuplicateVirtualWallet')
                ->error_message_is("Sorry, a virtual wallet account already exists. Only one virtual wallet account is allowed.");
        }
    }
};

subtest 'virtual account topup' => sub {
    my $virtual_wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRDW',
    });
    $virtual_wallet->email('test@binary.com');
    $virtual_wallet->set_default_account('USD');
    $virtual_wallet->save;

    my $oauth = BOM::Database::Model::OAuth->new;
    my $token = $oauth->store_access_token_only(1, $virtual_wallet->loginid);

    my $result = $rpc_ct->call_ok('topup_virtual', {token => $token})->has_no_error->result;
    is $result->{amount}, '10000.00', 'topup is ok';

    my $virtual_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $virtual_client->email('test@binary.com');
    $virtual_client->set_default_account('USD');
    $virtual_client->save;

    $token = $oauth->store_access_token_only(1, $virtual_client->loginid);

    $result = $rpc_ct->call_ok('topup_virtual', {token => $token})->has_no_error->result;
    is $result->{amount}, '10000.00', 'topup is ok';
};

done_testing;

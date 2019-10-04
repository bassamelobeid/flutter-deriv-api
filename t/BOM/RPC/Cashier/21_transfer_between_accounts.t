use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockTime qw(:all);
use Guard;
use Test::FailWarnings;
use Test::Warn;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;

# In the weekend the account transfers will be suspended. So we mock a valid day here
set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
scope_guard { restore_time() };

# unlimit daily transfer
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts(999);

populate_exchange_rates();

my ($t, $rpc_ct);

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

my $params = {
    language => 'EN',
    source   => 1,
    country  => 'in',
    args     => {},
};

my $method = 'transfer_between_accounts';

subtest 'Basic transfers' => sub {
    my $email      = 'new_email' . rand(999) . '@binary.com';
    my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_cr1, $client_cr2) {
        $user->add_client($_);
        $_->set_default_account('USD');
    }

    $client_cr1->payment_free_gift(
        currency => 'EUR',
        amount   => 1234,
        remark   => 'free gift',
    );

    $params->{token}      = BOM::Database::Model::AccessToken->new->create_token($client_cr1->loginid, 'test token');
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => $client_cr1->loginid,
        account_to   => $client_cr2->loginid,
        currency     => 'USD',
        amount       => 10
    };
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('simple transfer between sibling accounts');

    $params->{args}{account_from} = $client_cr2->loginid;
    $params->{args}{account_to}   = $client_cr1->loginid;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_no_error('can transfer using oauth token when account_from is not authorized client');

    $params->{token_type}         = 'api_token';
    $params->{args}{account_from} = $client_cr2->loginid;
    $params->{args}{account_to}   = $client_cr1->loginid;
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_message_is(
        'From account provided should be same as current authorized client.',
        'Cannot transfer using api token when account_from is not authorized client'
    );
};

subtest 'Virtual accounts' => sub {

    my $email1     = 'new_email' . rand(999) . '@binary.com';
    my $client_vr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $email1,
    });

    $client_vr1->set_default_account('USD');

    $client_vr1->payment_free_gift(
        currency => 'USD',
        amount   => 2345,
        remark   => 'free gift',
    );

    my $user1 = BOM::User->create(
        email          => $email1,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    $user1->add_client($client_vr1);

    my $email2 = 'new_email2' . rand(999) . '@binary.com';

    my $user2 = BOM::User->create(
        email          => $email2,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email2
    });

    $user2->add_client($client_cr2);
    $client_cr2->set_default_account('USD');

    $client_cr2->payment_free_gift(
        currency => 'USD',
        amount   => 3456,
        remark   => 'free gift',
    );

    my $client_cr3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email2
    });

    $user2->add_client($client_cr3);
    $client_cr3->set_default_account('USD');

    $client_cr3->payment_free_gift(
        currency => 'USD',
        amount   => 4567,
        remark   => 'free gift',
    );

    $params->{args}       = {};
    $params->{token}      = BOM::Database::Model::AccessToken->new->create_token($client_vr1->loginid, 'test token');
    $params->{token_type} = 'api_token';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_message_is('Permission denied.', 'Permission denied for vr account with api token');

    $params->{token_type} = 'oauth_token';
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('VR account allowed with oauth token')->result;
    is($result->{status}, '0', 'expected response for empty args');

    $params->{args} = {
        account_from => $client_cr2->loginid,
        currency     => 'USD',
        amount       => 11
    };

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is($result->{status}, '0', 'incomplete args (missing account_to) is treated same as empty args');

    $params->{args}{account_to} = $client_cr3->loginid;

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_message_is('Permission denied.', 'Permission denied for actual attempt to transfer');

    my $client_cr4 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email1
    });

    $user1->add_client($client_cr4);
    $client_cr4->set_default_account('USD');

    $client_cr4->payment_free_gift(
        currency => 'USD',
        amount   => 5678,
        remark   => 'free gift',
    );

    $params->{args} = {};
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error()->result;
    is($result->{accounts}[0]{loginid}, $client_cr4->loginid, 'real account loginid returned');
    cmp_ok($result->{accounts}[0]{balance}, '==', 5678, 'real account balance returned');
    is(scalar @{$result->{accounts}}, 1, 'only one account returned');

    $params->{args} = {
        account_from => $client_vr1->loginid,
        account_to   => $client_cr4->loginid,
        currency     => 'USD',
        amount       => 22
    };
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_message_is('Permission denied.', 'Cannot transfer from VR to real');

    $params->{args} = {
        account_from => $client_cr4->loginid,
        account_to   => $client_vr1->loginid,
        currency     => 'USD',
        amount       => 33
    };
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_message_is('Permission denied.', 'Cannot transfer from real to VR');

    cmp_ok($client_vr1->default_account->balance, '==', 2345, 'VR account balance unchanged');
    cmp_ok($client_cr4->default_account->balance, '==', 5678, 'Real account balance unchanged');

    my $client_cr5 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email1
    });

    $user1->add_client($client_cr5);
    $client_cr5->set_default_account('USD');

    $client_cr5->payment_free_gift(
        currency => 'USD',
        amount   => 6789,
        remark   => 'free gift',
    );

    $params->{args} = {
        account_from => $client_cr4->loginid,
        account_to   => $client_cr5->loginid,
        currency     => 'USD',
        amount       => 44
    };

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error()->result;
    ok $result->{status} && $result->{transaction_id}, 'Can transfer between sibling real accounts';
    cmp_ok($client_cr4->default_account->balance, '==', 5678 - 44, 'account_form debited');
    cmp_ok($client_cr5->default_account->balance, '==', 6789 + 44, 'account_to credited');

};

done_testing();

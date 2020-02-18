use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockTime qw(:all);
use Test::MockModule;
use Guard;
use Test::FailWarnings;
use Test::Warn;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates populate_exchange_rates_db/;
use LandingCompany::Registry;

# In the weekend the account transfers will be suspended. So we mock a valid day here
set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
scope_guard { restore_time() };

# unlimit daily transfer
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts(999);

populate_exchange_rates({BTC => 5500});

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

    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
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

subtest 'Fiat <-> Crypto account transfers' => sub {

    # ----- Test 1: Fiat -> Crypto -----

    my $email       = 'new_email' . rand(999) . '@binary.com';
    my $client_fiat = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $client_fiat->set_default_account('USD');

    my $client_crypto = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $client_crypto->set_default_account('BTC');

    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_fiat, $client_crypto) {
        $user->add_client($_);
    }

    $client_fiat->payment_free_gift(
        currency => 'USD',
        amount   => 10000,
        remark   => 'free gift',
    );

    my %emitted;
    my %mocked_storage;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->mock(
        'emit',
        sub {
            my ($event_name, $args) = @_;
            return 1 if $event_name ne 'client_transfer';
            my $client_from = BOM::User::Client->new({loginid => $args->{loginid_from}});
            my $client_to   = BOM::User::Client->new({loginid => $args->{loginid_to}});
            my $currencies  = LandingCompany::Registry::get($args->{lc_short})->legal_allowed_currencies;

            my $fiat_client = $currencies->{$client_from->currency}->{type} eq 'fiat' ? $client_from : $client_to;

            $mocked_storage{$fiat_client->loginid} += $args->{amount};
            if ($mocked_storage{$fiat_client->loginid} >= 1000) {
                $fiat_client->status->set('withdrawal_locked', 'test', 'internal_transfer over 1k');
            }
            $emitted{$event_name} = $fiat_client->loginid;
        });

    my $amount_to_transfer = 500;
    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_fiat->loginid, 'test token');
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => $client_fiat->loginid,
        account_to   => $client_crypto->loginid,
        currency     => 'USD',
        amount       => $amount_to_transfer
    };
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('simple transfer between sibling accounts');
    is($emitted{client_transfer}, $client_fiat->loginid, 'Event triggered to check for lifetime internal transfer');
    # reloads client
    $client_fiat = BOM::User::Client->new({loginid => $client_fiat->loginid});
    is($client_fiat->status->withdrawal_locked, undef, 'client is not withdrawal_locked');

    $amount_to_transfer = 600;
    $params->{args}->{amount} = $amount_to_transfer;
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('simple transfer between sibling accounts 2');
    # reloads client
    $client_fiat = BOM::User::Client->new({loginid => $client_fiat->loginid});
    is($client_fiat->status->withdrawal_locked->{reason}, 'internal_transfer over 1k', 'client is withdrawal_locked');

    # ----- Test 2: Fiat -> Crypto -> Fiat -----

    $email = 'new_email' . rand(999) . '@binary.com';
    my $client_fiat2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $client_fiat2->set_default_account('USD');

    my $client_crypto2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $client_crypto2->set_default_account('BTC');

    my $user2 = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_fiat2, $client_crypto2) {
        $user->add_client($_);
    }

    $client_fiat2->payment_free_gift(
        currency => 'USD',
        amount   => 10000,
        remark   => 'free gift',
    );

    $amount_to_transfer = 800;
    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_fiat2->loginid, 'test token');
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => $client_fiat2->loginid,
        account_to   => $client_crypto2->loginid,
        currency     => 'USD',
        amount       => $amount_to_transfer
    };
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('simple transfer between sibling account 3');
    is($emitted{client_transfer}, $client_fiat2->loginid, 'Event triggered to check for lifetime internal transfer');
    # reloads client
    $client_fiat2 = BOM::User::Client->new({loginid => $client_fiat2->loginid});
    is($client_fiat2->status->withdrawal_locked, undef, 'client is not withdrawal_locked');

    $amount_to_transfer = 0.125;    #625USD according to the custom rate set
    $params->{args} = {
        account_from => $client_crypto2->loginid,
        account_to   => $client_fiat2->loginid,
        currency     => 'BTC',
        amount       => $amount_to_transfer
    };

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('simple transfer between sibling accounts 4');
    # reloads client
    $client_fiat2 = BOM::User::Client->new({loginid => $client_fiat->loginid});
    is($client_fiat2->status->withdrawal_locked->{reason}, 'internal_transfer over 1k', 'client is withdrawal_locked');

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
    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_vr1->loginid, 'test token');
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

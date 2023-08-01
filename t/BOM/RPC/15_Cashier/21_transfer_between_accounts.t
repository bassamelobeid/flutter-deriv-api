use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockTime qw(:all);
use Test::MockModule;
use Guard;
use Test::FailWarnings;
use Test::Warn;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates populate_exchange_rates_db/;
use BOM::RPC::v3::MT5::Account;
use Test::BOM::RPC::Accounts;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::TradingPlatform;

my $redis = BOM::Config::Redis::redis_exchangerates_write();

sub _offer_to_clients {
    my $value         = shift;
    my $from_currency = shift;
    my $to_currency   = shift // 'USD';

    $redis->hmset("exchange_rates::${from_currency}_${to_currency}", offer_to_clients => $value);
}
_offer_to_clients(1, $_) for qw/BTC USD ETH UST EUR/;

# In the weekend the account transfers will be suspended. So we mock a valid day here
set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
scope_guard { restore_time() };

# Unlimited daily transfer
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts(999);

# disable routing to demo p01_ts02
my $p01_ts02_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02(0);

# disable routing to demo p01_ts02
my $p01_ts03_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03(0);

populate_exchange_rates({BTC => 5500});

my ($t, $rpc_ct);

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

my $params = {
    language => 'EN',
    source   => 1,
    country  => 'in',
    args     => {},
};

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
    $client_cr1->status->set('disabled', 'system', 'test');
    ok $client_cr1->status->disabled, "account is disabled";
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'DisabledClient',               'Correct error code if account_from is disabled';
    is $result->{error}->{message_to_client}, 'This account is unavailable.', 'Correct error message if account_from is disabled';
    $client_cr1->status->clear_disabled;
    $client_cr2->status->set('disabled', 'system', 'test');
    ok $client_cr2->status->disabled, "account is disabled";
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'DisabledAccount', 'Correct error code if account_to is disabled';
    is $result->{error}->{message_to_client}, "You cannot perform this action, as your account $params->{args}->{account_to} is currently disabled.",
        'Correct error message if account_to is disabled';
    $client_cr2->status->clear_disabled;

    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('simple transfer between sibling accounts');

    $params->{args}{account_from} = $client_cr2->loginid;
    $params->{args}{account_to}   = $client_cr1->loginid;
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('can transfer using oauth token when account_from is not authorized client');

    $params->{token_type}         = 'api_token';
    $params->{args}{account_from} = $client_cr2->loginid;
    $params->{args}{account_to}   = $client_cr1->loginid;
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_message_is(
        "You can only transfer from the current authorized client's account.",
        'Cannot transfer using api token when account_from is not authorized client'
    );
};

subtest 'Fiat <-> Crypto account transfers' => sub {

    # Test 1: Fiat -> Crypto

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

    my $amount_to_transfer = 199;
    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_fiat->loginid, 'test token');
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => $client_fiat->loginid,
        account_to   => $client_crypto->loginid,
        currency     => 'USD',
        amount       => $amount_to_transfer
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('simple transfer between sibling accounts');
    # Reloads client
    $client_fiat = BOM::User::Client->new({loginid => $client_fiat->loginid});
    is($client_fiat->status->allow_document_upload, undef, 'client is not allowed to upload documents');

    # Transaction should be blocked as client is unauthenticated and >200usd
    $amount_to_transfer = 100;
    $params->{args}->{amount} = $amount_to_transfer;
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    like $result->{error}->{message_to_client}, qr/To continue, you will need to verify your identity/,
        'Correct error message for 200USD transfer limit';

    # Attempted transfer will trigger allow_document_upload status
    $client_fiat = BOM::User::Client->new({loginid => $client_fiat->loginid});
    is($client_fiat->status->allow_document_upload->{reason}, 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT', 'client is allowed to upload documents');

    # Clear the status for further checks
    $client_fiat->status->clear_allow_document_upload;
    is($client_fiat->status->allow_document_upload, undef, 'client is not allowed to upload documents 1');

    # Total of 201 usd, client should be allowed to upload document
    $amount_to_transfer = 2;
    $params->{args}->{amount} = $amount_to_transfer;
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;

    # Reloads client
    $client_fiat = BOM::User::Client->new({loginid => $client_fiat->loginid});
    is($client_fiat->status->allow_document_upload->{reason}, 'FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT', 'client is allowed to upload documents 2');

};

subtest 'In status transfers_blocked Fiat <-> Crypto transfers are not allowed' => sub {

    my $email       = 'new_email' . rand(999) . '@binary.com';
    my $client_fiat = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $client_fiat->set_default_account('USD');

    $client_fiat->status->set('transfers_blocked', 'TEST', 'QIWI does not want funds to/from crypto');

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

    my $amount_to_transfer = 199;
    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_fiat->loginid, 'test token');
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => $client_fiat->loginid,
        account_to   => $client_crypto->loginid,
        currency     => 'USD',
        amount       => $amount_to_transfer
    };

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_message_is('Transfers are not allowed for these accounts.',
        'Correct error message when transfer from fiat to crypto when transfers is blocked');

    $client_crypto->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );

    $amount_to_transfer   = 0.2;
    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_crypto->loginid, 'test token');
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => $client_crypto->loginid,
        account_to   => $client_fiat->loginid,
        currency     => 'BTC',
        amount       => $amount_to_transfer
    };

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_message_is('Transfers are not allowed for these accounts.',
        'Correct error message when transfer from crypto to fiat when transfers is blocked');

};

subtest 'Crypto <-> Crypto account transfers' => sub {
    my $email      = 'new_email' . rand(999) . '@binary.com';
    my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $client_btc->set_default_account('BTC');

    my $client_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $client_eth->set_default_account('ETH');

    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_btc, $client_eth) {
        $user->add_client($_);
    }

    $client_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 2,
        remark   => 'free gift',
    );

    my $amount_to_transfer = 0.001;
    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_btc->loginid, 'test token');
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => $client_btc->loginid,
        account_to   => $client_eth->loginid,
        currency     => 'BTC',
        amount       => $amount_to_transfer
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('simple transfer between sibling accounts');
    # Reloads client
    $client_btc = BOM::User::Client->new({loginid => $client_btc->loginid});
    is($client_btc->status->allow_document_upload, undef, 'client is not allowed to upload documents');

    # Transaction should be blocked as client is unauthenticated and >1000usd
    $amount_to_transfer = 1;
    $params->{args}->{amount} = $amount_to_transfer;
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    like $result->{error}->{message_to_client}, qr/To continue, you will need to verify your identity/,
        'Correct error message for 1000USD transfer limit';

    # Attempted transfer will trigger allow_document_upload status
    $client_btc = BOM::User::Client->new({loginid => $client_btc->loginid});
    is($client_btc->status->allow_document_upload->{reason}, 'CRYPTO_TO_CRYPTO_TRANSFER_OVERLIMIT', 'client is allowed to upload documents');

    $client_btc->status->clear_allow_document_upload;
    is($client_btc->status->allow_document_upload, undef, 'client is not allowed to upload documents 1');
};

subtest 'Crypto <-> Fiat account transfers' => sub {
    my $email      = 'new_email' . rand(999) . '@binary.com';
    my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $client_usd->set_default_account('USD');

    my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $client_btc->set_default_account('BTC');

    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_btc, $client_usd) {
        $user->add_client($_);
    }

    $client_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 2,
        remark   => 'free gift',
    );

    my $amount_to_transfer = 0.001;
    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_btc->loginid, 'test token');
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => $client_btc->loginid,
        account_to   => $client_usd->loginid,
        currency     => 'BTC',
        amount       => $amount_to_transfer
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('simple transfer between sibling accounts');
    # Reloads client
    $client_btc = BOM::User::Client->new({loginid => $client_btc->loginid});
    is($client_btc->status->allow_document_upload, undef, 'client is not allowed to upload documents');

    # Transaction should be blocked as client is unauthenticated and >1000usd
    $amount_to_transfer = 0.2;
    $params->{args}->{amount} = $amount_to_transfer;
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    like $result->{error}->{message_to_client}, qr/To continue, you will need to verify your identity/,
        'Correct error message for 1000USD transfer limit';

    # Attempted transfer will trigger allow_document_upload status
    $client_btc = BOM::User::Client->new({loginid => $client_btc->loginid});
    is($client_btc->status->allow_document_upload->{reason}, 'CRYPTO_TO_FIAT_TRANSFER_OVERLIMIT', 'client is allowed to upload documents');

    $client_btc->status->clear_allow_document_upload;
    is($client_btc->status->allow_document_upload, undef, 'client is not allowed to upload documents 1');
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

    my $client_vr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $email1,
    });
    $user2->add_client($client_vr2);

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

    $params->{args} = {
        account_from => $client_cr2->loginid,
        account_to   => $client_cr3->loginid,
        currency     => 'USD',
        amount       => 10
    };
    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_vr2->loginid, 'test token');
    $params->{token_type} = 'api_token';
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_message_is('You cannot transfer between real accounts because the authorized client is virtual.',
        'Permission denied for vr account with api token');

    $params->{token_type} = 'oauth_token';
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
    ok $result->{status} && $result->{transaction_id}, 'Can transfer between sibling real accounts with oauth virtual token';
    cmp_ok($client_cr2->default_account->balance, '==', 3456 - 10, 'account_form debited');
    cmp_ok($client_cr3->default_account->balance, '==', 4567 + 10, 'account_to credited');

    # set token to that of another user
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_vr1->loginid, 'test token');
    $params->{args}  = {};
    $result =
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('VR account allowed if no transer is made')->result;
    is($result->{status}, '0', 'expected response for empty args');

    $params->{args} = {
        account_from => $client_cr2->loginid,
        currency     => 'USD',
        amount       => 11
    };

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
    is($result->{status}, '0', 'incomplete args (missing account_to) is treated same as empty args');

    $params->{args}{account_to} = $client_cr3->loginid;

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_message_is("You are not allowed to transfer from this account.",
        'Permission denied for actual attempt to transfer because token is for another user');

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
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error()->result;
    is(scalar @{$result->{accounts}}, 1, 'one accounts are returned');
    cmp_bag $result->{accounts},
        [{
            'demo_account' => 1,
            'account_type' => 'trading',
            'balance'      => '2345.00',
            'currency'     => 'USD',
            'loginid'      => $client_vr1->loginid
        }
        ],
        'Only virtual accounts are returned';

    $params->{args} = {
        account_from => $client_vr1->loginid,
        account_to   => $client_cr4->loginid,
        currency     => 'USD',
        amount       => 22
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_message_is('Transfer between real and virtual accounts is not allowed.',
        'Cannot transfer from VR to real');

    $params->{args} = {
        account_from => $client_cr4->loginid,
        account_to   => $client_vr1->loginid,
        currency     => 'USD',
        amount       => 33
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_message_is('Transfer between real and virtual accounts is not allowed.',
        'Cannot transfer from real to VR');

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

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error()->result;
    ok $result->{status} && $result->{transaction_id}, 'Can transfer between sibling real accounts';
    cmp_ok($client_cr4->default_account->balance, '==', 5678 - 44, 'account_form debited');
    cmp_ok($client_cr5->default_account->balance, '==', 6789 + 44, 'account_to credited');

};

subtest 'Get accounts list for transfer_between_accounts' => sub {
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $mock_account = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_account->mock(_is_financial_assessment_complete => sub { return 1 });
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(fully_authenticated => sub { return 1 });

    my $email       = 'new_email' . rand(999) . '@binary.com';
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code            => 'CR',
        email                  => $email,
        account_opening_reason => 'no reason',
    });
    $test_client->set_default_account('USD');
    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    $test_client->status->set('crs_tin_information', 'system', 'testing something');

    my $test_client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });
    $test_client_btc->set_default_account('BTC');
    $test_client_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 10,
        remark   => 'free gift',
    );
    $test_client_btc->status->set('crs_tin_information', 'system', 'testing something');
    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );
    $user->add_client($test_client);
    $user->add_client($test_client_btc);

    my $token = BOM::Platform::Token::API->new->create_token($test_client->loginid, 'test token');
    $params->{token}      = $token;
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {};
    my @real_accounts = ({
            loginid      => $test_client->loginid,
            balance      => num(1000),
            currency     => 'USD',
            account_type => 'trading',
            demo_account => 0,
        },
        {
            loginid      => $test_client_btc->loginid,
            balance      => num(10),
            currency     => 'BTC',
            account_type => 'trading',
            demo_account => 0,
        },
    );
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("no error for 'transfer_between_accounts' with no params");
    cmp_bag($rpc_ct->result->{accounts}, [@real_accounts], "all real binary accounts by empty 'transfer_between_accounts' call.");
    $params->{args} = {accounts => 'all'};
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("no error for 'transfer_between_accounts' with no params");
    cmp_bag($rpc_ct->result->{accounts}, [@real_accounts], "accounts=all returns all binary accounts because no MT5 account exists yet.");

    my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
    my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
    #create MT5 accounts
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'demo',
            mt5_account_type => 'financial',
            investPassword   => $DETAILS{investPassword},
            mainPassword     => $DETAILS{password}{main},
        },
    };
    $test_client->user->update_trading_password($DETAILS{password}{main});
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for demo mt5_new_account');

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial';
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for financial mt5_new_account');

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial_stp';
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for financial_stp mt5_new_account');

    my @mt5_accounts = ({
            loginid      => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'},
            balance      => num($DETAILS{balance}),
            currency     => 'USD',
            account_type => 'mt5',
            mt5_group    => 'real\p01_ts01\financial\svg_std_usd',
            demo_account => 0,
            status       => undef
        },
        {
            loginid      => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'},
            balance      => num($DETAILS{balance}),
            currency     => 'USD',
            account_type => 'mt5',
            mt5_group    => 'real\p01_ts01\financial\labuan_stp_usd',
            demo_account => 0,
            status       => undef
        },
    );
    $params->{args} = {accounts => 'all'};
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("no error for 'transfer_between_accounts' with no params");
    cmp_bag($rpc_ct->result->{accounts}, [@real_accounts, @mt5_accounts], "accounts=all returns all trading and mt5 accounts.");
    $test_client->status->set('disabled', 'system', 'test');
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'DisabledClient', 'Correct error code for disabled acount';
    is $result->{error}->{message_to_client}, 'This account is unavailable.',
        'Correct error message for perform action using disabled account`s token.';
    $test_client->status->clear_disabled;
    #mt5 suspended
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all(1);
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_error("no error for 'transfer_between_accounts' with accounts=all when mt5 suspended");
    cmp_bag($rpc_ct->result->{accounts}, [@real_accounts], "accounts=all returns only binary accounts when MT5 suspended");
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all(0);
};

subtest 'Current account is withdrawal_locked but its siblings can transfer between other two real accounts' => sub {
    #use Token of account that is withdrawal_locked
    my $email      = 'new_email' . rand(999) . '@binary.com';
    my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client_cr3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client_cr4 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client_cr5 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_cr1, $client_cr2, $client_cr3, $client_cr4, $client_cr5) {
        $user->add_client($_);
    }
    $client_cr1->set_default_account('USD');
    $client_cr2->set_default_account('BTC');
    $client_cr3->set_default_account('USD');
    $client_cr4->set_default_account('BTC');
    $client_cr5->set_default_account('USD');

    $client_cr2->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    $client_cr4->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    $client_cr1->status->set('withdrawal_locked', 'system', 'test');
    ok $client_cr1->status->withdrawal_locked, "account is withdrawal_locked";
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $params->{args}  = {
        account_from => $client_cr2->loginid,
        account_to   => $client_cr3->loginid,
        currency     => 'BTC',
        amount       => 0.00018182
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('simple transfer between sibling accounts even if current account is withdrawal_locked');

    # using token of current account but sibling (account_from) is disabled
    $client_cr2->status->set('disabled', 'system', 'test');
    ok $client_cr2->status->disabled, "account_from is disabled";
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'DisabledAccount', 'Correct error code if account_from is disabled';
    is $result->{error}->{message_to_client},
        "You cannot perform this action, as your account $params->{args}->{account_from} is currently disabled.",
        'Correct error message if account_from is disabled';
    $client_cr2->status->clear_disabled;

    # using token of current account but sibling (account_to) is disabled
    $client_cr3->status->set('disabled', 'system', 'test');
    ok $client_cr3->status->disabled, "account_to is disabled";
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'DisabledAccount', 'Correct error code if account_to is disabled';
    is $result->{error}->{message_to_client}, "You cannot perform this action, as your account $params->{args}->{account_to} is currently disabled.",
        'Correct error message if account_to is disabled';
    $client_cr3->status->clear_disabled;

    # using token of current account but sibling (account_from) is withdrawal_locked
    $client_cr2->status->set('withdrawal_locked', 'system', 'test');
    ok $client_cr2->status->withdrawal_locked, "account_from is withdrawal_locked";
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'WithdrawalLockedStatus', 'Correct error code if account_from is withdrawal_locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.',
        'Correct error message if account_from is withdrawal_locked';
    $client_cr2->status->clear_withdrawal_locked;

    # using token of current account but sibling (account_to) is withdrawal_locked
    $client_cr5->status->set('withdrawal_locked', 'system', 'test');
    ok $client_cr5->status->withdrawal_locked, "account_to is withdrawal_locked";

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $params->{args}  = {
        account_from => $client_cr4->loginid,
        account_to   => $client_cr5->loginid,
        currency     => 'BTC',
        amount       => 0.00018182
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('simple transfer between sibling accounts even if account_to is withdrawal_locked');
    $client_cr5->status->clear_withdrawal_locked;
    $client_cr1->status->clear_withdrawal_locked;
};

subtest 'Current account is no_withdrawal_or_trading but its siblings can transfer between other two real accounts' => sub {
    #use Token of account that is no_withdrawal_or_trading
    my $email      = 'new_email' . rand(999) . '@binary.com';
    my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client_cr3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client_cr4 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client_cr5 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_cr1, $client_cr2, $client_cr3, $client_cr4, $client_cr5) {
        $user->add_client($_);
    }
    $client_cr1->set_default_account('USD');
    $client_cr2->set_default_account('BTC');
    $client_cr3->set_default_account('USD');
    $client_cr4->set_default_account('BTC');
    $client_cr5->set_default_account('USD');

    $client_cr2->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    $client_cr4->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    $client_cr1->status->set('no_withdrawal_or_trading', 'system', 'test');
    ok $client_cr1->status->no_withdrawal_or_trading, "account is no_withdrawal_or_trading";
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');

    $params->{args} = {
        account_from => $client_cr2->loginid,
        account_to   => $client_cr3->loginid,
        currency     => 'BTC',
        amount       => 0.00018182
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('simple transfer between sibling accounts even if current account is no_withdrawal_or_trading');

    # using token of current account but sibling (account_from) is withdrawal_locked
    $client_cr2->status->set('no_withdrawal_or_trading', 'system', 'test');
    ok $client_cr2->status->no_withdrawal_or_trading, "account_from is no_withdrawal_or_trading";
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'NoWithdrawalOrTradingStatus', 'Correct error code if account_from is no_withdrawal_or_trading';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.',
        'Correct error message if account_from is no_withdrawal_or_trading';
    $client_cr2->status->clear_no_withdrawal_or_trading;
    # using token of current account but sibling (account_to) is no_withdrawal_or_trading
    $client_cr5->status->set('no_withdrawal_or_trading', 'system', 'test');
    ok $client_cr5->status->no_withdrawal_or_trading, "account_to is no_withdrawal_or_trading";

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $params->{args}  = {
        account_from => $client_cr4->loginid,
        account_to   => $client_cr5->loginid,
        currency     => 'BTC',
        amount       => 0.00018182
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('simple transfer between sibling accounts even if account_to is no_withdrawal_or_trading');
    $client_cr5->status->clear_no_withdrawal_or_trading;
    $client_cr1->status->clear_no_withdrawal_or_trading;
};

subtest 'Current account is cashier_locked but its siblings can transfer between other two real accounts' => sub {
    #use Token of account that is cashier_locked
    my $email      = 'new_email' . rand(999) . '@binary.com';
    my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client_cr3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_cr1, $client_cr2, $client_cr3) {
        $user->add_client($_);
    }
    $client_cr1->set_default_account('USD');
    $client_cr2->set_default_account('BTC');
    $client_cr3->set_default_account('USD');
    $client_cr2->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    #current acount is cashier locked
    $client_cr1->status->set('cashier_locked', 'system', 'test');
    ok $client_cr1->status->cashier_locked, "account is cashier_locked";
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');

    $params->{args} = {
        account_from => $client_cr2->loginid,
        account_to   => $client_cr3->loginid,
        currency     => 'BTC',
        amount       => 0.00018182
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('simple transfer between sibling accounts even if current account is cashier_locked');
    $client_cr1->status->clear_cashier_locked;
    # using token of current account but sibling (account_from) is cashier_locked
    $client_cr2->status->set('cashier_locked', 'system', 'test');
    ok $client_cr2->status->cashier_locked, "account_from is cashier_locked";
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'CashierLocked', 'Correct error code if account_from is cashier_locked';
    is $result->{error}->{message_to_client}, 'Your account cashier is locked. Please contact us for more information.',
        'Correct error message if account_from is cashier_locked';
    $client_cr2->status->clear_cashier_locked;
    # using token of current account but sibling (account_to) is cashier_locked
    $client_cr3->status->set('cashier_locked', 'system', 'test');
    ok $client_cr3->status->cashier_locked, "account_to is cashier_locked";
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'CashierLocked', 'Correct error code if account_to is cashier_locked';
    is $result->{error}->{message_to_client}, 'Your account cashier is locked. Please contact us for more information.',
        'Correct error message if account_to is cashier_locked';
    $client_cr3->status->clear_cashier_locked;
};

subtest 'Transfer to Sibling account when current account is withdrawal_locked or cashier_locked or no_withdrawal_or_trading' => sub {
    #use Token of account that is cashier_locked or withdrawal_locked
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
    }
    $client_cr1->set_default_account('USD');
    $client_cr2->set_default_account('BTC');
    $client_cr1->payment_free_gift(
        currency => 'USD',
        amount   => 500,
        remark   => 'free gift',
    );
    $client_cr1->status->set('cashier_locked', 'system', 'test');
    ok $client_cr1->status->cashier_locked, "account is cashier_locked";
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $params->{args}  = {
        account_from => $client_cr1->loginid,
        account_to   => $client_cr2->loginid,
        currency     => 'USD',
        amount       => 100
    };
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'CashierLocked', 'Correct error code if account_from is cashier_locked';
    is $result->{error}->{message_to_client}, 'Your account cashier is locked. Please contact us for more information.',
        'Correct error message if account_to is cashier_locked';
    $client_cr1->status->clear_cashier_locked;

    $client_cr1->status->set('withdrawal_locked', 'system', 'test');
    ok $client_cr1->status->withdrawal_locked, "account is withdrawal_locked";
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'WithdrawalLockedStatus', 'Correct error code if account_from is cashier_locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.',
        'Correct error message if account_from is withdrawal_locked';
    $client_cr1->status->clear_withdrawal_locked;

    $client_cr1->status->set('no_withdrawal_or_trading', 'system', 'test');
    ok $client_cr1->status->no_withdrawal_or_trading, "account is no_withdrawal_or_trading";
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'NoWithdrawalOrTradingStatus', 'Correct error code if account_from is cashier_locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.',
        'Correct error message if account_from is no_withdrawal_or_trading';
    $client_cr1->status->clear_no_withdrawal_or_trading;

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error(
        'simple transfer to sibling account when current account is not withdrawal_locked, cashier_locked & no_withdrawal_or_trading');
};

subtest 'Transfer from Sibling account when current account is withdrawal_locked or cashier_locked or no_withdrawal_or_trading' => sub {
    #use Token of account that is cashier_locked or withdrawal_locked
    my $email      = 'new_email' . rand(999) . '@binary.com';
    my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client_cr3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_cr1, $client_cr2, $client_cr3) {
        $user->add_client($_);
    }
    $client_cr1->set_default_account('USD');
    $client_cr2->set_default_account('BTC');
    $client_cr3->set_default_account('BTC');
    $client_cr2->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    $client_cr3->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    $client_cr1->status->set('cashier_locked', 'system', 'test');
    ok $client_cr1->status->cashier_locked, "account is cashier_locked";
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $params->{args}  = {
        account_from => $client_cr2->loginid,
        account_to   => $client_cr1->loginid,
        currency     => 'BTC',
        amount       => 0.00018182
    };
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'CashierLocked', 'Correct error code if account_to is cashier_locked';
    is $result->{error}->{message_to_client}, 'Your account cashier is locked. Please contact us for more information.',
        'Correct error message if account_to is cashier_locked';
    $client_cr1->status->clear_cashier_locked;
    $client_cr1->status->set('withdrawal_locked', 'system', 'test');
    ok $client_cr1->status->withdrawal_locked, "account is withdrawal_locked";
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('simple transfer from sibling account to current withdrawal_locked account');
    $client_cr1->status->clear_withdrawal_locked;

    $client_cr1->status->set('no_withdrawal_or_trading', 'system', 'test');
    ok $client_cr1->status->no_withdrawal_or_trading, "account is no_withdrawal_or_trading";
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $params->{args}{account_from} = $client_cr3->loginid;
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('simple transfer from sibling account to current no_withdrawal_or_trading account');
    $client_cr1->status->clear_no_withdrawal_or_trading;
};

subtest 'Transfer between virtual accounts' => sub {
    my $email     = 'virtual_transfer@deriv.com';
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $client_vdw = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRW',
    });
    my $client_vdw2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRW',
    });

    my $user = BOM::User->create(
        email    => $email,
        password => BOM::User::Password::hashpw('hello'),
    );
    $user->add_client($client_cr);
    $user->add_client($client_vr);
    $user->add_client($client_vdw);
    $user->add_client($client_vdw2);

    $client_cr->set_default_account('USD');
    $client_vr->set_default_account('USD');
    $client_vdw->set_default_account('USD');
    $client_vdw2->set_default_account('EUR');

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');
    $params->{args}  = {
        account_from => $client_vdw->loginid,
        account_to   => $client_vr->loginid,
        currency     => 'USD',
        amount       => 10
    };
    $params->{token_type} = 'oauth_token';
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->result;
    is_deeply $result->{error},
        {
        'message_to_client' => 'The sending account has insufficient funds for this transaction.',
        'code'              => 'TransferBetweenAccountsError'
        },
        'Correct error for insufficient balance';
    $client_vdw->payment_free_gift(
        currency => 'USD',
        amount   => 10,
        remark   => 'free gift',
    );

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('Transfer from virtual dwallet to virtual trading account is allowed');
    cmp_ok($client_vdw->default_account->balance, '==', 0,  'Wallet account balance changed');
    cmp_ok($client_vr->default_account->balance,  '==', 10, 'Virtual account balance changed');

    $params->{args}->@{qw/account_from account_to/} = ($client_vr->loginid, $client_vdw->loginid);
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_no_error('Transfer from virtual tranding to virtual dwallet account is allowed');
    cmp_ok($client_vdw->default_account->balance, '==', 10, 'Wallet account balance changed again');
    cmp_ok($client_vr->default_account->balance,  '==', 0,  'Virtual account balance changed again');

    $params->{args}->{account_from} = $client_vdw2->loginid;
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->result;
    is_deeply $result->{error},
        {
        'message_to_client' => 'Transfer between wallet accounts is not allowed.',
        'code'              => 'WalletAccountsNotAllowed'
        },
        'Transfer between wallet accounts will fail';

    subtest 'Transfer between virtual and real acccounts is not allowed' => sub {
        $params->{args}->{account_from} = $client_cr->loginid;
        for my $account_to ($client_vr->loginid, $client_vdw->loginid) {
            $params->{args}->{account_to} = $account_to;
            $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
            is $result->{error}->{code}, 'RealToVirtualNotAllowed', 'Transfer from real to virtual account is not allowed';
        }
        $params->{args}->{account_to} = $client_cr->loginid;
        for my $account_from ($client_vr->loginid, $client_vdw->loginid) {
            $params->{args}->{account_from} = $account_from;
            $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
            is $result->{error}->{code}, 'RealToVirtualNotAllowed', 'Transfer from virtual to real account is not allowed';
        }
    };
};

subtest 'Transfer between derivez accounts' => sub {
    # Create the cr account with  currency
    my $client     = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $client_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $client_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

    # Set up the client account currency
    $client_eth->account('ETH');
    $client_eur->account('EUR');

    # Top up the client account for each currency
    $client->payment_free_gift(
        currency => 'USD',
        amount   => 10,
        remark   => 'free gift',
    );
    $client_eth->payment_free_gift(
        currency => 'ETH',
        amount   => 10,
        remark   => 'free gift',
    );
    $client_eur->payment_free_gift(
        currency => 'EUR',
        amount   => 10,
        remark   => 'free gift',
    );

    # Create binary user and add the client to the user
    my $user = BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $user->add_client($client_eth);
    $user->add_client($client_eur);

    # Add the derivez account to the user
    my %derivez_account = (
        real => {login => 'EZR80000000'},
    );
    $user->add_loginid($derivez_account{real}{login});

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');

    # Preparing and mock get_user response data that we get from MT5
    my $async_get_user_response = {
        'leverage'      => 1000,
        'country'       => 'Indonesia',
        'phone'         => '',
        'group'         => 'real\\p02_ts01\\all\\svg_ez_usd',
        'email'         => 'test@deriv.com',
        'address'       => '',
        'zipCode'       => undef,
        'name'          => '',
        'rights'        => 481,
        'state'         => '',
        'balance'       => '0.00',
        'phonePassword' => undef,
        'login'         => 'EZR80000000',
        'city'          => '',
        'agent'         => 0,
        'color'         => 4278190080,
        'company'       => ''
    };
    $mock_async_call->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing and mock get_group response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'real\\p02_ts01\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };
    $mock_async_call->mock('get_group', sub { return Future->done($get_group_response); });

    # Setting up exchange rates
    my $redis          = BOM::Config::Redis::redis_exchangerates_write();
    my @exchange_rates = ({
            key    => 'exchange_rates::EUR_USD',
            values => {
                offer_to_clients => 1,
                quote            => '1.09113',
                epoch            => time
            }
        },
        {
            key    => 'exchange_rates::ETH_USD',
            values => {
                offer_to_clients => 1,
                quote            => '1919.99500',
                epoch            => time
            }});
    foreach my $entry (@exchange_rates) {
        $redis->hmset($entry->{key}, %{$entry->{values}});
    }

    # Generate the client auth token
    my $token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test token usd');
    my $token_eth = BOM::Platform::Token::API->new->create_token($client_eth->loginid, 'test token eth');
    my $token_eur = BOM::Platform::Token::API->new->create_token($client_eur->loginid, 'test token eur');

    # Mocking deposit to return true and evaluate the received amount
    my $received_amount;
    $mock_async_call->mock(
        'deposit',
        sub {
            my ($variable) = @_;

            $received_amount = $variable->{amount};

            return Future->done({status => 1});
        });

    # Mocking withdrawal to return true
    $mock_async_call->mock('withdrawal', sub { return Future->done({status => 1}); });

    subtest 'can deposit from CR account to derivez (USD)' => sub {
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_from => $client->loginid,
                account_to   => $derivez_account{real}{login},
                amount       => 5,
                currency     => 'USD',
            },
        };

        # Perform deposit test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can deposit from CR account to derivez (USD)");
        is $client->account->balance, '5.00', 'deposit it correct with the amount';
        is $received_amount,          '5',    'deposit to derivez is correct and applying exchange rate';
    };

    subtest 'can deposit from CR account to derivez (ETH)' => sub {
        my $params = {
            language => 'EN',
            token    => $token_eth,
            args     => {
                account_from => $client_eth->loginid,
                account_to   => $derivez_account{real}{login},
                amount       => 5,
                currency     => 'ETH',
            },
        };

        # Perform deposit test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can deposit from CR account to derivez (ETH)");
        is $client_eth->account->balance, '5.00000000', 'deposit it correct with the amount';
        is $received_amount,              '9503.98',    'deposit to derivez is correct and applying exchange rate';
    };

    subtest 'can deposit from CR account to derivez (EUR)' => sub {
        my $params = {
            language => 'EN',
            token    => $token_eur,
            args     => {
                account_from => $client_eur->loginid,
                account_to   => $derivez_account{real}{login},
                amount       => 5,
                currency     => 'EUR',
            },
        };

        # Perform deposit test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can deposit from CR account to derivez (EUR)");
        is $client_eur->account->balance, '5.00', 'deposit is correct';
        is $received_amount,              '5.40', 'deposit to derivez is correct and applying exchange rate';
    };

    subtest 'can withdraw from derivez account to CR (USD)' => sub {
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_from => $derivez_account{real}{login},
                account_to   => $client->loginid,
                amount       => 5,
                currency     => 'USD',
            },
        };

        # Perform withdraw test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can withdraw from derivez account to CR (USD)");
        is $client->account->balance, '10.00', 'withdrawal is correct and applying exchange rate';
    };

    subtest 'can withdraw from derivez account to CR (ETH)' => sub {
        my $params = {
            language => 'EN',
            token    => $token_eth,
            args     => {
                account_from => $derivez_account{real}{login},
                account_to   => $client_eth->loginid,
                amount       => 5,
                currency     => 'USD',
            },
        };

        # Perform withdraw test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can withdraw from derivez account to CR (ETH)");
        is $client_eth->account->balance, '5.00257813', 'withdrawal is correct and applying exchange rate';
    };

    subtest 'can withdraw from derivez account to CR (EUR)' => sub {
        my $params = {
            language => 'EN',
            token    => $token_eur,
            args     => {
                account_from => $derivez_account{real}{login},
                account_to   => $client_eur->loginid,
                amount       => 5,
                currency     => 'USD',
            },
        };

        # Perform withdraw test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can withdraw from derivez account to CR (EUR)");
        is $client_eur->account->balance, '9.54', 'withdrawal is correct and applying exchange rate';
    };

    subtest 'cannot deposit from CR account to derivez with mismatch currency' => sub {
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_from => $client->loginid,
                account_to   => $derivez_account{real}{login},
                amount       => 5,
                currency     => 'ETH',
            },
        };

        # Perform deposit test
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'currency conflict')
            ->error_message_is('Currency provided is different from account currency.',
            'cannot deposit from CR account to derivez with mismatch currency');
    };

    subtest 'cannot withdraw from derivez account to CR with mismatch currency' => sub {
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_from => $client->loginid,
                account_to   => $derivez_account{real}{login},
                amount       => 5,
                currency     => 'ETH',
            },
        };

        # Perform withdraw test
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'currency conflict')
            ->error_message_is('Currency provided is different from account currency.',
            'cannot withdraw from derivez account to CR with mismatch currency');
    };

    $mock_async_call->unmock_all();
};

# reset
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02($p01_ts02_load);
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03($p01_ts03_load);

subtest 'Transfer between ctrader accounts' => sub {
    my $mocked_ctrader = Test::MockModule->new('BOM::TradingPlatform::CTrader');
    my $mock_apidata   = {
        ctid_create                 => {userId => 1001},
        ctid_getuserid              => {userId => 1001},
        ctradermanager_getgrouplist => [{name => 'ctrader_all_svg_std_usd', groupId => 1}],
        trader_create               => {
            login                 => 100001,
            groupName             => 'ctrader_all_svg_std_usd',
            registrationTimestamp => 123456,
            depositCurrency       => 'USD',
            balance               => 0,
            moneyDigits           => 2
        },
        trader_get => {
            login                 => 100001,
            groupName             => 'ctrader_all_svg_std_usd',
            registrationTimestamp => 123456,
            depositCurrency       => 'USD',
            balance               => 0,
            moneyDigits           => 2
        },
        tradermanager_gettraderlightlist => [{traderId => 1001, login => 100001}],
        ctid_linktrader                  => {ctidTraderAccountId => 1001},
        tradermanager_deposit            => {balanceHistoryId    => 1},
        tradermanager_withdraw           => {balanceHistoryId    => 1}};

    my $received_amount;

    my %ctrader_mock = (
        call_api => sub {
            $mocked_ctrader->mock(
                'call_api',
                shift // sub {
                    my ($self, %payload) = @_;
                    my $method         = $payload{method};
                    my $trader_balance = $mock_apidata->{trader_get}->{balance};
                    $mock_apidata->{trader_get}->{balance} = $trader_balance + $payload{payload}->{amount} if $method eq 'tradermanager_deposit';

                    if ($method eq 'tradermanager_withdraw') {
                        if ($trader_balance - $payload{payload}->{amount} >= 0) {
                            $mock_apidata->{trader_get}->{balance} = $trader_balance - $payload{payload}->{amount};
                        } else {
                            return {errorCode => 'NOT_ENOUGH_MONEY'};
                        }
                    }

                    if ($method eq 'tradermanager_deposit') {
                        $received_amount = $payload{payload}->{amount};
                    }

                    return $mock_apidata->{$method};
                });
        },
    );

    $ctrader_mock{call_api}->();
    # Create the cr account with  currency
    my $client     = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $client_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $client_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

    # Set up the client account currency
    $client_eth->account('ETH');
    $client_eur->account('EUR');

    # Top up the client account for each currency
    $client->payment_free_gift(
        currency => 'USD',
        amount   => 10,
        remark   => 'free gift',
    );
    $client_eth->payment_free_gift(
        currency => 'ETH',
        amount   => 10,
        remark   => 'free gift',
    );
    $client_eur->payment_free_gift(
        currency => 'EUR',
        amount   => 10,
        remark   => 'free gift',
    );

    # Create binary user and add the client to the user
    $client->email('ctradertransferbetweenaccount@test.com');
    my $user = BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $user->add_client($client_eth);
    $user->add_client($client_eur);
    $client->binary_user_id($user->id);

    my $ctrader = BOM::TradingPlatform->new(
        platform    => 'ctrader',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client));

    my $account = $ctrader->new_account(
        account_type => "real",
        market_type  => "all",
        platform     => "ctrader"
    );

    # Add the ctrader account to the user
    my %ctrader_account = (
        real => {login => 'CTR100001'},
    );

    # Setting up exchange rates
    my $redis          = BOM::Config::Redis::redis_exchangerates_write();
    my @exchange_rates = ({
            key    => 'exchange_rates::EUR_USD',
            values => {
                offer_to_clients => 1,
                quote            => '1.09113',
                epoch            => time
            }
        },
        {
            key    => 'exchange_rates::ETH_USD',
            values => {
                offer_to_clients => 1,
                quote            => '1919.99500',
                epoch            => time
            }});
    foreach my $entry (@exchange_rates) {
        $redis->hmset($entry->{key}, %{$entry->{values}});
    }

    # Generate the client auth token
    my $token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test token usd');
    my $token_eth = BOM::Platform::Token::API->new->create_token($client_eth->loginid, 'test token eth');
    my $token_eur = BOM::Platform::Token::API->new->create_token($client_eur->loginid, 'test token eur');

    subtest 'can deposit from CR account to ctrader (USD)' => sub {
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_from => $client->loginid,
                account_to   => $ctrader_account{real}{login},
                amount       => 5,
                currency     => 'USD',
            },
        };

        # Perform deposit test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can deposit from CR account to ctrader (USD)");
        is $client->account->balance, '5.00', 'deposit it correct with the amount';
        is $received_amount,          '5.00', 'deposit to ctrader is correct and applying exchange rate';
    };

    subtest 'can deposit from CR account to ctrader (ETH)' => sub {
        my $params = {
            language => 'EN',
            token    => $token_eth,
            args     => {
                account_from => $client_eth->loginid,
                account_to   => $ctrader_account{real}{login},
                amount       => 5,
                currency     => 'ETH',
            },
        };

        # Perform deposit test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can deposit from CR account to ctrader (ETH)");
        is $client_eth->account->balance, '5.00000000', 'deposit it correct with the amount';
        is $received_amount,              '9503.98',    'deposit to ctrader is correct and applying exchange rate';
    };

    subtest 'can deposit from CR account to ctrader (EUR)' => sub {
        my $params = {
            language => 'EN',
            token    => $token_eur,
            args     => {
                account_from => $client_eur->loginid,
                account_to   => $ctrader_account{real}{login},
                amount       => 5,
                currency     => 'EUR',
            },
        };

        # Perform deposit test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can deposit from CR account to ctrader (EUR)");
        is $client_eur->account->balance, '5.00', 'deposit is correct';
        is $received_amount,              '5.40', 'deposit to ctrader is correct and applying exchange rate';
    };

    subtest 'can withdraw from ctrader account to CR (USD)' => sub {
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_from => $ctrader_account{real}{login},
                account_to   => $client->loginid,
                amount       => 5,
                currency     => 'USD',
            },
        };

        # Perform withdraw test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can withdraw from ctrader account to CR (USD)");
        is $client->account->balance, '10.00', 'withdrawal is correct and applying exchange rate';
    };

    subtest 'can withdraw from ctrader account to CR (ETH)' => sub {
        my $params = {
            language => 'EN',
            token    => $token_eth,
            args     => {
                account_from => $ctrader_account{real}{login},
                account_to   => $client_eth->loginid,
                amount       => 5,
                currency     => 'USD',
            },
        };

        # Perform withdraw test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can withdraw from ctrader account to CR (ETH)");
        is $client_eth->account->balance, '5.00257813', 'withdrawal is correct and applying exchange rate';
    };

    subtest 'can withdraw from ctrader account to CR (EUR)' => sub {
        my $params = {
            language => 'EN',
            token    => $token_eur,
            args     => {
                account_from => $ctrader_account{real}{login},
                account_to   => $client_eur->loginid,
                amount       => 5,
                currency     => 'USD',
            },
        };

        # Perform withdraw test
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("can withdraw from ctrader account to CR (EUR)");
        is $client_eur->account->balance, '9.54', 'withdrawal is correct and applying exchange rate';
    };

    subtest 'cannot deposit from CR account to ctrader with mismatch currency' => sub {
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_from => $client->loginid,
                account_to   => $ctrader_account{real}{login},
                amount       => 5,
                currency     => 'ETH',
            },
        };

        # Perform deposit test
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('CurrencyShouldMatch', 'currency conflict')
            ->error_message_is('Currency provided is different from account currency.',
            'cannot deposit from CR account to ctrader with mismatch currency');
    };

    subtest 'cannot withdraw from ctrader account to CR with mismatch currency' => sub {
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_from => $client->loginid,
                account_to   => $ctrader_account{real}{login},
                amount       => 5,
                currency     => 'ETH',
            },
        };

        # Perform withdraw test
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('CurrencyShouldMatch', 'currency conflict')
            ->error_message_is('Currency provided is different from account currency.',
            'cannot withdraw from ctrader account to CR with mismatch currency');
    };
};

done_testing();

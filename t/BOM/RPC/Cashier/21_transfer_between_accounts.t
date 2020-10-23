use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockTime qw(:all);
use Test::MockModule;
use Guard;
use Test::FailWarnings;
use Test::Warn;

use BOM::Test::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates populate_exchange_rates_db/;
use LandingCompany::Registry;
use BOM::RPC::v3::MT5::Account;
use Test::BOM::RPC::Accounts;
use BOM::Config::Runtime;
use BOM::Config::Redis;

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
    $client_cr1->status->set('disabled', 'system', 'test');
    ok $client_cr1->status->disabled, "account is disabled";
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'DisabledClient',               'Correct error code if account_from is disabled';
    is $result->{error}->{message_to_client}, 'This account is unavailable.', 'Correct error message if account_from is disabled';
    $client_cr1->status->clear_disabled;
    $client_cr2->status->set('disabled', 'system', 'test');
    ok $client_cr2->status->disabled, "account is disabled";
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'PermissionDenied',   'Correct error code if account_to is disabled';
    is $result->{error}->{message_to_client}, 'Permission denied.', 'Correct error message if account_to is disabled';
    $client_cr2->status->clear_disabled;

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
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('simple transfer between sibling accounts');
    # Reloads client
    $client_fiat = BOM::User::Client->new({loginid => $client_fiat->loginid});
    is($client_fiat->status->allow_document_upload, undef, 'client is not allowed to upload documents');

    # Transaction should be blocked as client is unauthenticated and >200usd
    $amount_to_transfer = 100;
    $params->{args}->{amount} = $amount_to_transfer;
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
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
    $rpc_ct->call_ok($method, $params)->has_no_system_error->result;

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

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_message_is('Transfers are not allowed for these accounts.',
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

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_message_is('Transfers are not allowed for these accounts.',
        'Correct error message when transfer from cryoto to fiat when transfers is blocked');

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

subtest 'Get accounts list for transfer_between_accounts' => sub {
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $mock_account = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_account->mock(
        _is_financial_assessment_complete => sub { return 1 },
        _throttle                         => sub { return 0 });
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
            account_type => 'binary',
        },
        {
            loginid      => $test_client_btc->loginid,
            balance      => num(10),
            currency     => 'BTC',
            account_type => 'binary'
        },
    );
    $rpc_ct->call_ok($method, $params)->has_no_error("no error for $method with no params");
    cmp_bag($rpc_ct->result->{accounts}, [@real_accounts], "all real binary accounts by empty $method call.");
    $params->{args} = {accounts => 'all'};
    $rpc_ct->call_ok($method, $params)->has_no_error("no error for $method with no params");
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
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for demo mt5_new_account');

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial';
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for financial mt5_new_account');

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial_stp';
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for financial_stp mt5_new_account');

    my @mt5_accounts = ({
            loginid      => 'MTR' . $ACCOUNTS{'real\svg_financial_Bbook'},
            balance      => num($DETAILS{balance}),
            currency     => 'USD',
            account_type => 'mt5',
            mt5_group    => 'real\\svg_financial_Bbook'
        },
        {
            loginid      => 'MTR' . $ACCOUNTS{'real\labuan_financial_stp'},
            balance      => num($DETAILS{balance}),
            currency     => 'USD',
            account_type => 'mt5',
            mt5_group    => 'real\\labuan_financial_stp'
        },
    );
    $params->{args} = {accounts => 'all'};
    $rpc_ct->call_ok($method, $params)->has_no_error("no error for $method with no params");
    cmp_bag($rpc_ct->result->{accounts}, [@real_accounts, @mt5_accounts], "accounts=all returns all binary accounts + MT5.");
    $test_client->status->set('disabled', 'system', 'test');
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'DisabledClient', 'Correct error code for disabled acount';
    is $result->{error}->{message_to_client}, 'This account is unavailable.',
        'Correct error message for perform action using disabled account`s token.';
    $test_client->status->clear_disabled;
    #mt5 suspended
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all(1);
    $rpc_ct->call_ok($method, $params)->has_no_error("no error for $method with accounts=all when mt5 suspended");
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
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_no_error('simple transfer between sibling accounts even if current account is withdrawal_locked');

    # using token of current account but sibling (account_from) is disabled
    $client_cr2->status->set('disabled', 'system', 'test');
    ok $client_cr2->status->disabled, "account_from is disabled";
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'PermissionDenied',   'Correct error code if account_from is disabled';
    is $result->{error}->{message_to_client}, 'Permission denied.', 'Correct error message if account_from is disabled';
    $client_cr2->status->clear_disabled;

    # using token of current account but sibling (account_to) is disabled
    $client_cr3->status->set('disabled', 'system', 'test');
    ok $client_cr3->status->disabled, "account_to is disabled";
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'PermissionDenied',   'Correct error code if account_to is disabled';
    is $result->{error}->{message_to_client}, 'Permission denied.', 'Correct error message if account_to is disabled';
    $client_cr3->status->clear_disabled;

    # using token of current account but sibling (account_from) is withdrawal_locked
    $client_cr2->status->set('withdrawal_locked', 'system', 'test');
    ok $client_cr2->status->withdrawal_locked, "account_from is withdrawal_locked";
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if account_from is withdrawal_locked';
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
    $rpc_ct->call_ok($method, $params)
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
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_no_error('simple transfer between sibling accounts even if current account is no_withdrawal_or_trading');

    # using token of current account but sibling (account_from) is withdrawal_locked
    $client_cr2->status->set('no_withdrawal_or_trading', 'system', 'test');
    ok $client_cr2->status->no_withdrawal_or_trading, "account_from is no_withdrawal_or_trading";
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if account_from is no_withdrawal_or_trading';
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
    $rpc_ct->call_ok($method, $params)
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
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_no_error('simple transfer between sibling accounts even if current account is cashier_locked');
    $client_cr1->status->clear_cashier_locked;
    # using token of current account but sibling (account_from) is cashier_locked
    $client_cr2->status->set('cashier_locked', 'system', 'test');
    ok $client_cr2->status->cashier_locked, "account_from is cashier_locked";
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if account_from is cashier_locked';
    is $result->{error}->{message_to_client}, 'Your account cashier is locked. Please contact us for more information.',
        'Correct error message if account_from is cashier_locked';
    $client_cr2->status->clear_cashier_locked;
    # using token of current account but sibling (account_to) is cashier_locked
    $client_cr3->status->set('cashier_locked', 'system', 'test');
    ok $client_cr3->status->cashier_locked, "account_to is cashier_locked";
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if account_to is cashier_locked';
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
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if account_from is cashier_locked';
    is $result->{error}->{message_to_client}, 'Your account cashier is locked. Please contact us for more information.',
        'Correct error message if account_to is cashier_locked';
    $client_cr1->status->clear_cashier_locked;

    $client_cr1->status->set('withdrawal_locked', 'system', 'test');
    ok $client_cr1->status->withdrawal_locked, "account is withdrawal_locked";
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if account_from is cashier_locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.',
        'Correct error message if account_from is withdrawal_locked';
    $client_cr1->status->clear_withdrawal_locked;

    $client_cr1->status->set('no_withdrawal_or_trading', 'system', 'test');
    ok $client_cr1->status->no_withdrawal_or_trading, "account is no_withdrawal_or_trading";
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if account_from is cashier_locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.',
        'Correct error message if account_from is no_withdrawal_or_trading';
    $client_cr1->status->clear_no_withdrawal_or_trading;

    $rpc_ct->call_ok($method, $params)
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
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if account_to is cashier_locked';
    is $result->{error}->{message_to_client}, 'Your account cashier is locked. Please contact us for more information.',
        'Correct error message if account_to is cashier_locked';
    $client_cr1->status->clear_cashier_locked;
    $client_cr1->status->set('withdrawal_locked', 'system', 'test');
    ok $client_cr1->status->withdrawal_locked, "account is withdrawal_locked";
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_no_error('simple transfer from sibling account to current withdrawal_locked account');
    $client_cr1->status->clear_withdrawal_locked;

    $client_cr1->status->set('no_withdrawal_or_trading', 'system', 'test');
    ok $client_cr1->status->no_withdrawal_or_trading, "account is no_withdrawal_or_trading";
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $params->{args}{account_from} = $client_cr3->loginid;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_no_error('simple transfer from sibling account to current no_withdrawal_or_trading account');
    $client_cr1->status->clear_no_withdrawal_or_trading;
};

done_testing();

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockObject;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper                          qw(test_schema build_wsapi_test);
use BOM::Test::Helper::Utility                 qw(random_email_address);
use BOM::Test::Helper::Client                  qw(create_client);

use BOM::Platform::Token::API;
use BOM::User;
use BOM::User::Password;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use await;

my $t = build_wsapi_test({language => 'EN'});
my $m = BOM::Platform::Token::API->new;

my $email = random_email_address;
my $user  = BOM::User->create(
    email          => $email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client = create_client(
    'CR', undef,
    {
        email          => $email,
        residence      => 'id',
        place_of_birth => 'id',
        binary_user_id => $user->id,
    });
$client->set_default_account('BTC');
$user->add_client($client);
my $client_token = $m->create_token($client->loginid, 'test token', ['read', 'payments']);

subtest 'Crypto cashier calls' => sub {
    $t->await::authorize({authorize => $client_token});

    my $error_response = {
        code    => 'InvalidRequest',
        message => "Cashier API doesn't support the selected provider or operation.",
    };
    my $ws_response = $t->await::cashier({
        cashier  => 'deposit',
        provider => 'crypto',
        type     => 'url',
    });
    test_schema(cashier => $ws_response);
    cmp_deeply $ws_response->{error}, $error_response, 'Returns error when "type: url" used for crypto provider'
        or diag explain $ws_response;

    my $rpc_response    = {};
    my $mocked_response = Test::MockObject->new();
    $mocked_response->mock('is_error', sub { 0 });
    $mocked_response->mock('result',   sub { $rpc_response });
    {
        no warnings qw(redefine once);    ## no critic (ProhibitNoWarnings)

        *MojoX::JSON::RPC::Client::ReturnObject::new = sub {
            return $mocked_response;
        }
    }

    $rpc_response = {
        action  => 'deposit',
        deposit => {
            address => 'sample_deposit_address',
        },
    };
    $ws_response = $t->await::cashier({
        cashier  => 'deposit',
        provider => 'crypto',
        type     => 'api',
    });
    test_schema(cashier => $ws_response);
    cmp_deeply $ws_response->{cashier}, $rpc_response, 'Expected response for cashier:deposit received';

    $rpc_response = {
        action   => 'withdraw',
        withdraw => {
            dry_run => 1,
        },
    };
    $ws_response = $t->await::cashier({
        cashier  => 'withdraw',
        provider => 'crypto',
        type     => 'api',
        address  => 'sample_withdrawal_address',
        amount   => 0.005,
        dry_run  => 1,
    });
    test_schema(cashier => $ws_response);
    cmp_deeply $ws_response->{cashier}, $rpc_response, 'Expected response for cashier:withdraw (dry-run) received';

    $rpc_response = {
        action   => 'withdraw',
        withdraw => {
            id             => 123,
            status_code    => 'LOCKED',
            status_message => 'sample status message',
        },
    };
    $ws_response = $t->await::cashier({
        cashier  => 'withdraw',
        provider => 'crypto',
        type     => 'api',
        address  => 'sample_withdrawal_address',
        amount   => 0.005,
    });
    test_schema(cashier => $ws_response);
    cmp_deeply $ws_response->{cashier}, $rpc_response, 'Expected response for cashier:withdraw received';

    $rpc_response = {
        id          => 123,
        status_code => 'CANCELLED',
    };
    $ws_response = $t->await::cashier_withdrawal_cancel({
        cashier_withdrawal_cancel => 1,
        id                        => 123,
    });
    test_schema(cashier_withdrawal_cancel => $ws_response);
    cmp_deeply $ws_response->{cashier_withdrawal_cancel}, $rpc_response, 'Expected response for cashier_withdrawal_cancel received';

    $rpc_response = {
        crypto => [{
                address_hash     => 'deposit_address_hash',
                address_url      => 'https://blockchain.url/address/',
                amount           => 0.005,
                id               => 123,
                status_code      => 'PENDING',
                status_message   => 'deposit status message',
                submit_date      => Date::Utility->new()->epoch,
                transaction_type => 'deposit',
                transaction_hash => 'deposit_transaction_hash',
                transaction_url  => 'https://blockchain.url/tx/',
                confirmations    => 0,
            },
            {
                address_hash     => 'withdrawal_address_hash',
                address_url      => 'https://blockchain.url/address/',
                amount           => 0.002,
                id               => 124,
                status_code      => 'VERIFIED',
                status_message   => 'withdrawal status message',
                submit_date      => Date::Utility->new()->epoch,
                transaction_type => 'withdrawal',
            },
        ],
    };
    $ws_response = $t->await::cashier_payments({
        cashier_payments => 1,
        provider         => 'crypto',
        transaction_type => 'all',
    });
    test_schema(cashier_payments => $ws_response);
    cmp_deeply $ws_response->{cashier_payments}, $rpc_response, 'Expected response for cashier_payments received';
};

subtest 'crypto_config call' => sub {

    my $rpc_response    = {};
    my $mocked_response = Test::MockObject->new();
    $mocked_response->mock('is_error', sub { 0 });
    $mocked_response->mock('result',   sub { $rpc_response });
    {
        no warnings qw(redefine once);    ## no critic (ProhibitNoWarnings)

        *MojoX::JSON::RPC::Client::ReturnObject::new = sub {
            return $mocked_response;
        }
    }

    $rpc_response = {
        currencies_config => {
            BTC   => {minimum_withdrawal => 0.00059166},
            ETH   => {minimum_withdrawal => 0.01030783},
            tUSDT => {
                minimum_withdrawal => 100,
                minimum_deposit    => 1
            }

        },
    };
    my $ws_response = $t->await::crypto_config({
        crypto_config => '1',
    });

    test_schema(crypto_config => $ws_response);
    cmp_deeply $ws_response->{crypto_config}, $rpc_response, 'Expected response for crypto_config received';

};

subtest 'crypto_estimations call' => sub {

    my $rpc_response = {
        "BTC" => {
            "withdrawal_fee" => {
                "value"       => 0.0001,
                "unique_id"   => "c84a793b-8a87-7999-ce10-9b22f7ceead3",
                "expiry_time" => 1689305114,
            }}};

    my $mocked_response = Test::MockObject->new();
    $mocked_response->mock('is_error', sub { 0 });
    $mocked_response->mock('result',   sub { $rpc_response });
    {
        no warnings qw(redefine once);    ## no critic (ProhibitNoWarnings)

        *MojoX::JSON::RPC::Client::ReturnObject::new = sub {
            return $mocked_response;
        }
    }

    my $ws_response = $t->await::crypto_estimations({
        crypto_estimations => '1',
        currency_code      => 'BTC',
    });

    test_schema(crypto_estimations => $ws_response);
    cmp_deeply $ws_response->{crypto_estimations}, $rpc_response, 'Expected response for crypto_estimations received';

};

$t->finish_ok;

done_testing();

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

use BOM::Database::Model::OAuth;
use BOM::User;
use BOM::User::Password;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use await;

my $t     = build_wsapi_test({language => 'EN'});
my $oauth = BOM::Database::Model::OAuth->new;

my $email = random_email_address;
my $user  = BOM::User->create(
    email          => $email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client1 = create_client(
    'CR', undef,
    {
        email          => $email,
        residence      => 'id',
        place_of_birth => 'id',
        binary_user_id => $user->id,
    });
$client1->set_default_account('BTC');
$user->add_client($client1);

my ($client1_token) = $oauth->store_access_token_only(1, $client1->loginid);

my $client2 = create_client(
    'CR', undef,
    {
        email          => $email,
        residence      => 'id',
        place_of_birth => 'id',
        binary_user_id => $user->id,
    });
$client2->set_default_account('BTC');
$user->add_client($client2);
my ($client2_token) = $oauth->store_access_token_only(1, $client2->loginid);

subtest 'Crypto cashier calls with multiple tokens' => sub {
    $t->await::authorize({authorize => 'MULTI', tokens => [$client1_token, $client2_token]});

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
    my $ws_response = $t->await::cashier({
        cashier  => 'deposit',
        loginid  => $client2->loginid,
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
        loginid  => $client2->loginid,
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
        loginid  => $client2->loginid,
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
        loginid                   => $client2->loginid,
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
        loginid          => $client2->loginid,
        subscribe        => 1,
        provider         => 'crypto',
        transaction_type => 'all',
    });
    test_schema(cashier_payments => $ws_response);
    cmp_deeply $ws_response->{cashier_payments}, $rpc_response, 'Expected response for cashier_payments received';
};

$t->finish_ok;

done_testing();

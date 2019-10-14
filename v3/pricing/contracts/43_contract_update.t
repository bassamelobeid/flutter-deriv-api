#!perl

use strict;
use warnings;

use Test::Most;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use await;
use Date::Utility;
use Data::Dumper;
use BOM::Database::Model::OAuth;

initialize_realtime_ticks_db();
my $t = build_wsapi_test();

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now,
    });

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});

$client->deposit_virtual_funds;
my $user = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($client);

subtest 'attempt contract_update before authorized' => sub {
    my $res = $t->await::contract_update({
            contract_update   => 1,
            contract_id       => 123,
            update_parameters => {}});
    ok $res->{error}, 'error';
    is $res->{error}->{code},    'AuthorizationRequired', 'error code - AuthorizationRequired';
    is $res->{error}->{message}, 'Please log in.',        'error message - Please log in.';
};

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
my $authorize = $t->await::authorize({authorize => $token});

subtest 'contract_update' => sub {
    my $res = $t->await::contract_update({
            contract_update   => 1,
            contract_id       => 123,
            update_parameters => {
                take_profit => {
                    operation => 'update',
                    value     => 1,
                },
            }});
    is $res->{msg_type}, 'contract_update', 'msg_type - contract_update';
    ok $res->{error}, 'error';
    is $res->{error}->{code}, 'ContractNotFound', 'error code - ContractNotFound';
    is $res->{error}->{message}, 'Contract not found for contract id: 123.', 'error message - Contract not found for contract id: 123.';

    my $proposal_res = $t->await::proposal({
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "stake",
        "contract_type" => "MULTUP",
        "currency"      => "USD",
        "symbol"        => "R_100",
        "multiplier"    => 10,
    });

    my $buy_res = $t->await::buy({
        buy   => $proposal_res->{proposal}->{id},
        price => 100,
    });

    ok $buy_res->{buy}->{transaction_id}, 'contract bought successfully';

    $res = $t->await::contract_update({
            contract_update   => 1,
            contract_id       => $buy_res->{buy}->{contract_id},
            update_parameters => {
                take_profit => {
                    operation => 'something',
                    value     => 1,
                },
            }});
    ok $res->{error}, 'error';
    is $res->{error}->{code}, 'InputValidationFailed', 'error code - InputValidationFailed';
    is $res->{error}->{message}, 'Input validation failed: update_parameters/take_profit/operation',
        'error message - Input validation failed: update_parameters/take_profit/operation';

    $res = $t->await::contract_update({
            contract_update   => 1,
            contract_id       => $buy_res->{buy}->{contract_id},
            update_parameters => {
                something => {
                    operation => 'update',
                    value     => 1,
                },
            }});
    ok $res->{error}, 'error';
    is $res->{error}->{code}, 'InputValidationFailed', 'error code - InputValidationFailed';
    is $res->{error}->{message}, 'Input validation failed: update_parameters',
        'error message - Input validation failed: update_parameters';


    $res = $t->await::contract_update({
            contract_update   => 1,
            contract_id       => $buy_res->{buy}->{contract_id},
            update_parameters => {
                take_profit => {
                    operation => 'update',
                    value     => 10,
                },
            }});
    ok $res->{contract_update}->{status}==1, 'update successfully';
    ok $res->{contract_update}->{barrier_value}, 'barrier value';
    is $res->{contract_update}->{type}, 'take_profit';
};

subtest 'contrcat_update on unsupported contract type' => sub {
    my $proposal_res = $t->await::proposal({
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "stake",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "symbol"        => "R_100",
        "duration_unit" => "m",
        "duration"      => 5,
    });

    my $buy_res = $t->await::buy({
        buy   => $proposal_res->{proposal}->{id},
        price => 100,
    });

    ok $buy_res->{buy}->{transaction_id}, 'contract bought successfully';

    my $res = $t->await::contract_update({
            contract_update   => 1,
            contract_id       => $buy_res->{buy}->{contract_id},
            update_parameters => {
                take_profit => {
                    operation => 'update',
                    value     => 1,
                },
            }});
    ok $res->{error}, 'error';
    is $res->{error}->{code}, 'UpdateNotAllowed', 'error code - UpdateNotAllowed';
    is $res->{error}->{message}, 'Update is not allowed for this contract.',
        'error message - Update is not allowed for this contract.';
};

subtest 'contract_update subscribe=1' => sub {
    my $proposal_res = $t->await::proposal({
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "stake",
        "currency"      => "USD",
        "symbol"        => "R_100",
        "contract_type" => "MULTUP",
        "multiplier"    => 10,
    });

    my $buy_res = $t->await::buy({
        buy       => $proposal_res->{proposal}->{id},
        price     => 100,
        subscribe => 1,
    });

    ok $buy_res->{buy}->{transaction_id}, 'contract bought successfully';
    ok $buy_res->{subscription}->{id},    'has subscription id';

    my $poc_res = $t->await::proposal_open_contract({
            proposal_open_contract => 1,
            subscribe              => 1,
            contract_id            => $buy_res->{buy}->{contract_id}});

    ok $poc_res->{error}, 'subscription error';
    is $poc_res->{error}{code}, 'AlreadySubscribed', 'error code - AlreadySubscribed';
    is $poc_res->{error}{message}, 'You are already subscribed to proposal_open_contract.',
        'error message - You are already subscribed to proposal_open_contract.';

    my $update_res = $t->await::contract_update({
            contract_update   => 1,
            contract_id       => $buy_res->{buy}->{contract_id},
            update_parameters => {
                take_profit => {
                    operation => 'update',
                    value     => 1,
                },
            },
            subscribe => 1,
        });
    ok $update_res->{contract_update}{status} == 1, 'contract_update successful';
    ok $update_res->{subscription}{id}, 'return subscription id when subscribe';
    cmp_ok $buy_res->{subscription}{id}, "ne", $update_res->{subscription}{id}, 'subscription id is not equals to previous buy subscription id';

    my $poc_res2 = $t->await::proposal_open_contract({
            proposal_open_contract => 1,
            subscribe              => 1,
            contract_id            => $buy_res->{buy}->{contract_id}});

    ok $poc_res2->{error}, 'subscription error';
    is $poc_res2->{error}{code}, 'AlreadySubscribed', 'error code - AlreadySubscribed';
    is $poc_res2->{error}{message}, 'You are already subscribed to proposal_open_contract.',
        'error message - You are already subscribed to proposal_open_contract.';
};

done_testing();
